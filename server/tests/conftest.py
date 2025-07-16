import asyncio
import logging
import sys
from pathlib import Path
from types import TracebackType
from typing import Generator, NamedTuple, Optional, Type, TypeVar
from unittest.mock import Mock
from urllib.parse import quote

import httpx
import pytest
import pytest_asyncio
from asgi_lifespan import LifespanManager
from core import Kanae
from fastapi import FastAPI, Request
from testcontainers.core.container import DockerContainer
from testcontainers.core.exceptions import ContainerStartException
from testcontainers.core.image import DockerImage
from testcontainers.core.utils import raise_for_deprecated_parameter
from testcontainers.core.waiting_utils import wait_container_is_ready, wait_for_logs
from testcontainers.postgres import PostgresContainer
from utils.config import KanaeConfig
from utils.limiter.extension import (
    KanaeLimiter,
    RateLimitExceeded,
    get_remote_address,
    rate_limit_exceeded_handler,
)
from utils.limiter.middleware import LimiterASGIMiddleware, LimiterMiddleware
from valkey import Valkey
from valkey.exceptions import ConnectionError
from yarl import URL

if sys.version_info >= (3, 11):
    from typing import AsyncGenerator, Self
else:
    from typing_extensions import AsyncGenerator, Self

BE = TypeVar("BE", bound=BaseException)

ROOT = Path(__file__).parents[2]
DOCKERFILE_PATH = ROOT / "docker" / "pg-test" / "Dockerfile"
CONFIG_PATH = ROOT / "server" / "config.yml"

config = KanaeConfig(CONFIG_PATH)


async def _async_rate_limit_exceeded_handler(request: Request, exc: RateLimitExceeded):
    return await rate_limit_exceeded_handler(request, exc)


class ValkeyContainer(DockerContainer):
    def __init__(
        self,
        image: str = "valkey/valkey:latest",
        port: int = 6379,
        password: str | None = None,
        **kwargs,
    ) -> None:
        raise_for_deprecated_parameter(kwargs, "port_to_expose", "port")
        super().__init__(image, **kwargs)
        self.port = port
        self.password = password
        self.with_exposed_ports(self.port)
        if self.password:
            self.with_command(f"valkey-server --requirepass {self.password}")

    @wait_container_is_ready(ConnectionError)
    def _connect(self) -> None:
        client = self.get_client()
        if not client.ping():
            raise ConnectionError("Could not connect to Valkey")

    def get_client(self, **kwargs) -> Valkey:
        return Valkey(
            host=self.get_container_host_ip(),
            port=self.get_exposed_port(self.port),
            password=self.password,
            **kwargs,
        )

    def get_connection_url(self, dbname: str | None = None) -> str:
        if self._container is None:
            raise ContainerStartException("container has not been started")

        host = self.get_container_host_ip()
        port = self.get_exposed_port(self.port)
        url = f"valkey://{host}:{port}"

        if self.password:
            quoted_password = quote(self.password, safe=" +")
            url = f"valkey://default:{quoted_password}@{host}:{port}"

        if dbname:
            url = f"{url}/{dbname}"
        return url

    def start(self) -> Self:
        super().start()
        self._connect()
        return self


class KanaeServices(NamedTuple):
    postgres: PostgresContainer
    valkey: ValkeyContainer


class KanaeTestClient:
    def __init__(self, app: Kanae, *, base_url: Optional[str] = None):
        self._config = app.config
        self._host = self._config["kanae"]["host"]
        self._port = self._config["kanae"]["port"]

        self._transport = httpx.ASGITransport(app=app)

        self.client = httpx.AsyncClient(
            transport=self._transport,
            base_url=base_url
            or str(URL.build(scheme="http", host=self._host, port=self._port)),
        )

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(
        self,
        exc_type: Optional[Type[BE]],
        exc: Optional[BE],
        traceback: Optional[TracebackType],
    ) -> None:
        await self.client.aclose()


@pytest.fixture(scope="session")
def get_app() -> Kanae:
    return Kanae(config=config)


@pytest.fixture(scope="session")
def setup() -> Generator[KanaeServices, None, None]:
    with DockerImage(path=ROOT, dockerfile_path=DOCKERFILE_PATH) as image:
        with PostgresContainer(str(image)) as postgres, ValkeyContainer() as valkey:
            wait_for_logs(postgres, "ready", timeout=15.0)
            wait_for_logs(valkey, "accept connections tcp", timeout=15.0)

            yield KanaeServices(postgres, valkey)


@pytest.fixture(scope="session")
def valkey() -> Generator[ValkeyContainer, None, None]:
    with ValkeyContainer() as valkey:
        wait_for_logs(valkey, "accept connections tcp", timeout=15.0)
        yield valkey


@pytest_asyncio.fixture(scope="function")
async def app(
    get_app: Kanae, setup: KanaeServices
) -> AsyncGenerator[KanaeTestClient, None]:
    get_app.config["postgres_uri"] = setup.postgres.get_connection_url(driver=None)
    async with (
        LifespanManager(app=get_app),
        KanaeTestClient(app=get_app) as client,
    ):
        yield client


@pytest_asyncio.fixture(
    scope="function",
    params=[
        (LimiterMiddleware, rate_limit_exceeded_handler),
        (LimiterASGIMiddleware, _async_rate_limit_exceeded_handler),
    ],
)
async def build_fastapi_app(request, valkey: ValkeyContainer):
    def _factory(**limiter_args):
        middleware, exception_handler = request.param

        test_config = KanaeConfig(CONFIG_PATH)
        test_config["kanae"]["limiter"]["storage_uri"] = valkey.get_connection_url()

        limiter_args.setdefault("key_func", get_remote_address)
        limiter_args.setdefault("config", test_config)
        limiter = KanaeLimiter(**limiter_args)

        # There is no point of connection to PostgreSQL
        # As we are running this on the function scope, and are sending tons of redis connections
        app = FastAPI()
        app.state.limiter = limiter
        app.state.loop = asyncio.get_event_loop()
        app.add_exception_handler(RateLimitExceeded, exception_handler)
        app.add_middleware(middleware)
        mock_handler = Mock()
        mock_handler.level = logging.INFO
        limiter.logger.addHandler(mock_handler)
        return app, limiter

    yield _factory

    # Constantly reset to clean out cleans
    # Removes constant unexpected 429 errors
    await _factory()[1]._reset()
