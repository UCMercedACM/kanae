import asyncio
from contextlib import asynccontextmanager
from typing import Literal, NamedTuple, Optional

import asyncpg
from fastapi import FastAPI
from typing_extensions import Self
from utils.config import KanaeConfig


class VersionInfo(NamedTuple):
    major: int
    minor: int
    micro: int
    releaselevel: Literal["main", "alpha", "beta", "final"]

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.micro}-{self.releaselevel}"


KANAE_NAME = "Kanae - ACM @ UC Merced's API"
KANAE_DESCRIPTION = "Internal backend server for ACM @ UC Merced"
KANAE_VERSION: VersionInfo = VersionInfo(
    major=0, minor=1, micro=0, releaselevel="final"
)


class Kanae(FastAPI):
    pool: asyncpg.Pool

    def __init__(
        self,
        *,
        loop: Optional[asyncio.AbstractEventLoop] = None,
        config: KanaeConfig,
    ):
        self.loop: asyncio.AbstractEventLoop = (
            loop or asyncio.get_event_loop_policy().get_event_loop()
        )
        super().__init__(
            title=KANAE_NAME,
            version=str(KANAE_VERSION),
            description=KANAE_DESCRIPTION,
            loop=self.loop,
            redoc_url="/docs",
            docs_url=None,
            lifespan=self.lifespan,
        )
        self.config = config

    @asynccontextmanager
    async def lifespan(self, app: Self):
        async with asyncpg.create_pool(dsn=self.config["postgres_uri"]) as app.pool:
            yield
