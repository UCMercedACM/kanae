from pathlib import Path
from types import TracebackType
from typing import AsyncGenerator, Generator, Optional, Self, Type, TypeVar

import httpx
import pytest
import pytest_asyncio
from asgi_lifespan import LifespanManager
from core import Kanae
from migrations import Migrations, create_migrations_table_from_connection
from testcontainers.core.generic import DbContainer
from testcontainers.postgres import PostgresContainer
from utils.config import KanaeConfig
from yarl import URL

BE = TypeVar("BE", bound=BaseException)

config = KanaeConfig(Path(__file__).parents[1] / "config.yml")


class KanaeTestClient:
    def __init__(self, app: Kanae, config: KanaeConfig):
        self.db_container = PostgresContainer(
            image="postgres:17-alpine", driver="asyncpg"
        )
        self._host = config["kanae"]["host"]
        self._port = config["kanae"]["port"]
        self._transport = httpx.ASGITransport(
            app=app, client=(config["kanae"]["host"], config["kanae"]["port"])
        )
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


@pytest.fixture
def get_app() -> Kanae:
    return Kanae(config=config)


@pytest.fixture(scope="session", autouse=True)
def setup() -> Generator[DbContainer]:
    with PostgresContainer(driver=None) as container:
        yield container


@pytest_asyncio.fixture(scope="session")
async def server(get_app: Kanae, setup: DbContainer) -> AsyncGenerator[KanaeTestClient]:
    config.shim("postgres_uri", setup.get_connection_url())
    await create_migrations_table_from_connection(config["postgres_uri"])
    async with (
        LifespanManager(app=get_app),
        Migrations(config["postgres_uri"]) as mg,
        KanaeTestClient(app=get_app, config=config) as test_client,
    ):
        await mg.upgrade()
        yield test_client
