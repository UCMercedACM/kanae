from pathlib import Path
from types import TracebackType
from typing import AsyncGenerator, Generator, Optional, Self, Type, TypeVar

import httpx
import pytest
import pytest_asyncio
from asgi_lifespan import LifespanManager
from core import Kanae
from testcontainers.core.image import DockerImage
from testcontainers.core.waiting_utils import wait_for_logs
from testcontainers.postgres import PostgresContainer
from utils.config import KanaeConfig
from yarl import URL

BE = TypeVar("BE", bound=BaseException)

ROOT = Path(__file__).parents[2]
DOCKERFILE_PATH = ROOT / "docker" / "pg-test" / "Dockerfile"
CONFIG_PATH = ROOT / "server" / "config.yml"

config = KanaeConfig(CONFIG_PATH)


class KanaeTestClient:
    def __init__(self, app: Kanae):
        self._host = app.config["kanae"]["host"]
        self._port = app.config["kanae"]["port"]
        self._transport = httpx.ASGITransport(app=app, client=(self._host, self._port))
        self.client = httpx.AsyncClient(
            transport=self._transport,
            base_url=str(URL.build(scheme="http", host=self._host, port=self._port)),
        )

    async def close(self) -> None:
        await self.client.aclose()

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(
        self,
        exc_type: Optional[Type[BE]],
        exc: Optional[BE],
        traceback: Optional[TracebackType],
    ) -> None:
        await self.close()


@pytest.fixture(scope="session")
def get_app() -> Kanae:
    return Kanae(config=config)


@pytest.fixture(scope="session")
def setup() -> Generator[PostgresContainer]:
    with DockerImage(
        path=ROOT, dockerfile_path=DOCKERFILE_PATH, tag="kanae-pg-test:latest"
    ) as image:
        with PostgresContainer(str(image)) as container:
            wait_for_logs(container, "ready", timeout=15.0)
            yield container


@pytest_asyncio.fixture(scope="function")
async def app(
    get_app: Kanae, setup: PostgresContainer
) -> AsyncGenerator[KanaeTestClient]:
    get_app.config.replace("postgres_uri", setup.get_connection_url(driver=None))
    async with (
        LifespanManager(app=get_app),
        KanaeTestClient(app=get_app) as client,
    ):
        yield client
