import asyncio
import datetime
import logging
import uuid
from collections.abc import AsyncGenerator, AsyncIterator, Callable, Generator
from pathlib import Path
from types import TracebackType
from typing import Any, Literal, NamedTuple, Optional, Self, TypedDict, Unpack, cast
from unittest.mock import Mock
from urllib.parse import quote

import asyncpg
import httpx
import pytest
import pytest_asyncio
from asgi_lifespan import LifespanManager
from fastapi import FastAPI, Request, Response
from fastapi_pagination import add_pagination
from starlette.middleware.cors import CORSMiddleware
from testcontainers.core.container import DockerContainer
from testcontainers.core.exceptions import ContainerStartException
from testcontainers.core.image import DockerImage
from testcontainers.core.network import Network
from testcontainers.core.utils import raise_for_deprecated_parameter
from testcontainers.core.wait_strategies import LogMessageWaitStrategy
from testcontainers.core.waiting_utils import WaitStrategy
from testcontainers.postgres import PostgresContainer
from yarl import URL

from core import Kanae, KanaeConfig, find_config
from routes import router
from utils.checks import Role
from utils.glide import GlideManager
from utils.limiter import get_remote_address
from utils.limiter.extension import (
    KanaeLimiter,
    RateLimitExceeded,
    rate_limit_exceeded_handler,
)
from utils.limiter.middleware import LimiterASGIMiddleware, LimiterMiddleware
from utils.ory import KanaeSession, KratosIdentity, OryClient

_CONFIG_PATH = find_config()
_DOCKERFILE = Path("tests/docker/Dockerfile")

_KANAE_CONFIG = KanaeConfig.load_from_file(_CONFIG_PATH)

# We need to "fake" the webhook master key because it's an operator secret
_TEST_WEBHOOK_MASTER_KEY = "00" * 32

_FAKE_COOKIE = "fake-kratos-session"
_DISCOVER_TABLES_SQL = """
SELECT format('%I.%I', table_schema, table_name) AS qname
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
ORDER BY table_name
"""


async def _async_rate_limit_exceeded_handler(
    request: Request, exc: RateLimitExceeded
) -> Response:
    return await rate_limit_exceeded_handler(request, exc)


### Types/Structs


class KanaeServices(NamedTuple):
    postgres: PostgresContainer
    valkey: "ValkeyContainer"


class _LimiterFactoryKwargs(TypedDict, total=False):
    key_func: Callable[..., str]
    config: KanaeConfig
    enabled: bool
    headers_enabled: bool
    key_style: Literal["endpoint", "url"]


class _DockerContainerKwargs(TypedDict, total=False):
    docker_client_kw: dict[str, Any] | None
    command: str | None
    env: dict[str, str] | None
    name: str | None
    ports: list[int] | None
    volumes: list[tuple[str, str, str]] | None
    network: Network | None
    network_aliases: list[str] | None
    _wait_strategy: WaitStrategy | None


class _PermissionKey(NamedTuple):
    namespace: str
    resource: str
    relation: str
    subject_id: str


### Custom containers


class ValkeyContainer(DockerContainer):
    def __init__(
        self,
        image: str = "valkey/valkey:latest",
        port: int = 6379,
        password: str | None = None,
        **kwargs: Unpack[_DockerContainerKwargs],
    ) -> None:
        raise_for_deprecated_parameter(
            cast("dict[Any, Any]", kwargs), "port_to_expose", "port"
        )
        super().__init__(image, **kwargs)
        self.port = port
        self.password = password
        self.with_exposed_ports(self.port)
        if self.password:
            self.with_command(f"valkey-server --requirepass {self.password}")
        self.waiting_for(LogMessageWaitStrategy("Ready to accept connections tcp"))

    def get_connection_url(self, dbname: str | None = None) -> str:
        if self._container is None:
            msg = "container has not been started"
            raise ContainerStartException(msg)

        host = self.get_container_host_ip()
        port = self.get_exposed_port(self.port)
        url = f"valkey://{host}:{port}"

        if self.password:
            quoted_password = quote(self.password, safe=" +")
            url = f"valkey://default:{quoted_password}@{host}:{port}"

        if dbname:
            url = f"{url}/{dbname}"
        return url


### Fake/test clients


class _FakeCacheableWhoami:
    __slots__ = ("_owner",)

    def __init__(self, owner: "FakeOryClient") -> None:
        self._owner = owner

    async def __call__(self, cookie: str) -> Optional[KanaeSession]:
        return self._owner.session

    # These has to be async to work as they are mocking the real ones
    async def cache_invalidate(self, cookie: str) -> None:
        return None


class FakeOryClient:
    __slots__ = (
        "client",
        "deleted_identities",
        "permissions",
        "purged_subjects",
        "revoked_all_sessions",
        "revoked_sessions",
        "session",
        "whoami",
    )

    def __init__(self, client: httpx.AsyncClient) -> None:
        self.client = client
        self.session: Optional[KanaeSession] = None
        self.permissions: set[_PermissionKey] = set()
        self.revoked_sessions: list[str] = []
        self.revoked_all_sessions: list[str] = []
        self.purged_subjects: list[str] = []
        self.deleted_identities: list[str] = []
        self.whoami: _FakeCacheableWhoami = _FakeCacheableWhoami(self)

    async def check_permission(
        self,
        namespace: str,
        resource: str,
        relation: str,
        subject_id: str,
    ) -> bool:
        key = _PermissionKey(namespace, str(resource), relation, str(subject_id))
        return key in self.permissions

    async def list_roles(self, subject_id: str) -> AsyncIterator[str]:
        for key in self.permissions:
            if (
                key.namespace == "Role"
                and key.relation == "member"
                and key.subject_id == str(subject_id)
            ):
                yield key.resource

    async def revoke_session(self, session_id: str) -> None:
        self.revoked_sessions.append(session_id)

    def login_as(
        self,
        *roles: Role,
        identity_id: Optional[str] = None,
        email: str = "test@test.local",
        aal: Literal["aal1", "aal2"] = "aal1",
        authenticated_at: Optional[datetime.datetime] = None,
    ) -> str:
        identity_id = identity_id or str(uuid.uuid4())
        now = datetime.datetime.now(datetime.UTC)
        self.session = KanaeSession(
            id=uuid.uuid4(),
            active=True,
            expires_at=now + datetime.timedelta(days=1),
            authenticated_at=authenticated_at or now,
            authenticator_assurance_level=aal,
            issued_at=now,
            identity=KratosIdentity(
                id=identity_id,
                schema_id="default",
                traits={
                    "email": email,
                    "name": email.split("@", maxsplit=1)[0],
                    "display_name": email,
                },
            ),
        )
        for role in roles:
            self.permissions.add(
                _PermissionKey("Role", role.value, "member", identity_id)
            )
        self.client.cookies.set("ory_kratos_session", _FAKE_COOKIE)
        return identity_id

    def logout(self) -> None:
        self.session = None
        self.client.cookies.delete("ory_kratos_session")

    async def grant(
        self,
        namespace: str,
        resource: str,
        relation: str,
        subject_id: Optional[str] = None,
        *,
        subject_set: Optional[dict[str, str]] = None,
    ) -> None:
        if subject_id is not None:
            self.permissions.add(
                _PermissionKey(namespace, str(resource), relation, str(subject_id))
            )

    async def revoke(
        self,
        namespace: str,
        resource: str,
        relation: str,
        subject_id: Optional[str] = None,
        *,
        subject_set: Optional[dict[str, str]] = None,
    ) -> None:
        if subject_id is not None:
            self.permissions.discard(
                _PermissionKey(namespace, str(resource), relation, str(subject_id))
            )

    async def revoke_all_sessions(self, identity_id: str) -> None:
        self.revoked_all_sessions.append(identity_id)

    async def purge(self, subject_id: str) -> None:
        self.purged_subjects.append(subject_id)
        self.permissions = {
            key for key in self.permissions if key.subject_id != str(subject_id)
        }

    async def delete_identity(self, identity_id: str) -> None:
        self.deleted_identities.append(identity_id)


class KanaeTestClient:
    def __init__(self, app: Kanae, *, base_url: Optional[str] = None) -> None:
        self._config = app.config
        self._host = self._config.kanae.host
        self._port = self._config.kanae.port

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
        exc_type: Optional[type[BaseException]],
        exc: Optional[BaseException],
        traceback: Optional[TracebackType],
    ) -> None:
        await self.client.aclose()


### Fake ory fixtures


@pytest.fixture(scope="function")
def fake_ory(client: KanaeTestClient, kanae: Kanae) -> FakeOryClient:
    fake = FakeOryClient(client=client.client)
    kanae.ory = cast("OryClient", fake)
    return fake


@pytest.fixture(scope="function")
def make_session(fake_ory: FakeOryClient) -> Callable[..., str]:
    return fake_ory.login_as


### Testcontainer fixtures


@pytest.fixture(scope="session")
def valkey() -> Generator[ValkeyContainer, None, None]:
    with ValkeyContainer() as valkey:
        yield valkey


@pytest.fixture(scope="session")
def setup() -> Generator[KanaeServices, None, None]:
    with (
        DockerImage(
            path=_DOCKERFILE.parents[2],
            dockerfile_path=_DOCKERFILE,
            tag="kanae-pg-test:latest",
        ) as image,
        PostgresContainer(str(image)) as postgres,
        ValkeyContainer() as valkey,
    ):
        yield KanaeServices(postgres, valkey)


### App-based fixtures


@pytest.fixture(scope="session")
def get_app() -> Kanae:
    return Kanae(config=_KANAE_CONFIG)


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def _truncate_sql(setup: KanaeServices) -> str:
    dsn = setup.postgres.get_connection_url(driver=None)

    connection = await asyncpg.connect(dsn)

    try:
        rows = await connection.fetch(_DISCOVER_TABLES_SQL)
    finally:
        await connection.close()

    if not rows:
        return ""

    tables = ", ".join(r["qname"] for r in rows)
    return f"TRUNCATE TABLE {tables} RESTART IDENTITY CASCADE"


### Actual running clients and apps fixtures


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def _running_app(kanae: Kanae) -> AsyncGenerator[KanaeTestClient, None]:
    async with (
        LifespanManager(app=kanae),
        KanaeTestClient(app=kanae) as test_client,
    ):
        yield test_client


@pytest.fixture(scope="session")
def kanae(setup: KanaeServices) -> Kanae:
    """Mirrors production-version of Kanae"""
    test_app = Kanae(config=_KANAE_CONFIG)
    test_app.include_router(router)
    test_app.add_middleware(
        CORSMiddleware,
        allow_origins=_KANAE_CONFIG.kanae.allowed_origins,
        allow_credentials=True,
        allow_methods=["GET", "PUT", "POST", "DELETE", "OPTIONS", "PATCH"],
        allow_headers=["Content-Type"],
    )
    add_pagination(test_app)
    test_app.limiter = router.limiter
    test_app.config.postgres_uri = setup.postgres.get_connection_url(driver=None)

    test_valkey_uri = setup.valkey.get_connection_url()
    test_app.config.kanae.limiter["storage_uri"] = test_valkey_uri
    test_app.limiter.storage_uri = test_valkey_uri
    test_app.config.ory = test_app.config.ory.model_copy(
        update={"kratos_webhook_master_key": _TEST_WEBHOOK_MASTER_KEY}
    )
    return test_app


@pytest_asyncio.fixture(scope="function", loop_scope="session")
async def client(
    _running_app: KanaeTestClient, kanae: Kanae, _truncate_sql: str
) -> AsyncGenerator[KanaeTestClient, None]:
    yield _running_app

    if _truncate_sql:
        await kanae.pool.execute(_truncate_sql)

    await kanae.limiter._reset()
    _running_app.client.cookies.clear()


@pytest_asyncio.fixture(
    scope="function",
    params=[
        (LimiterMiddleware, rate_limit_exceeded_handler),
        (LimiterASGIMiddleware, _async_rate_limit_exceeded_handler),
    ],
)
async def build_fastapi_app(
    request: pytest.FixtureRequest, valkey: ValkeyContainer
) -> AsyncGenerator[Callable[..., tuple[FastAPI, KanaeLimiter]], None]:
    async with GlideManager(uri=valkey.get_connection_url()) as manager:

        def _factory(
            **limiter_args: Unpack[_LimiterFactoryKwargs],
        ) -> tuple[FastAPI, KanaeLimiter]:
            middleware, exception_handler = request.param

            test_config = KanaeConfig.load_from_file(_CONFIG_PATH)
            test_config.kanae.limiter["storage_uri"] = valkey.get_connection_url()

            limiter_args.setdefault("key_func", get_remote_address)
            limiter_args.setdefault("config", test_config)
            limiter = KanaeLimiter(**limiter_args)
            limiter.attach(manager)

            # There is no point of connection to PostgreSQL
            # As we are running this on the function scope, and are sending tons of redis connections
            app = FastAPI()
            app.limiter = limiter  # ty: ignore[unresolved-attribute]
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
