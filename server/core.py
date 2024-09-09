import asyncio
from contextlib import asynccontextmanager
from typing import Literal, NamedTuple, Optional

import asyncpg
from fastapi import FastAPI
from typing_extensions import Self
from utils.config import AppConfig


class VersionInfo(NamedTuple):
    major: int
    minor: int
    micro: int
    releaselevel: Literal["main", "alpha", "beta", "final"]

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.micro}-{self.releaselevel}"


VERSION: VersionInfo = VersionInfo(major=0, minor=1, micro=0, releaselevel="final")

NAME = "ACM @ UC Merced API"
DESCRIPTION = """
Internal backend server for ACM @ UC Merced
"""


class ServerApp(FastAPI):
    pool: asyncpg.Pool

    def __init__(
        self,
        *,
        loop: Optional[asyncio.AbstractEventLoop] = None,
        config: AppConfig,
    ):
        self.loop: asyncio.AbstractEventLoop = (
            loop or asyncio.get_event_loop_policy().get_event_loop()
        )
        super().__init__(
            title=NAME,
            version=str(VERSION),
            description=DESCRIPTION,
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
