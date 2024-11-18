from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import Literal, NamedTuple, Optional, Generator, TYPE_CHECKING, Any

from itertools import chain
from collections import OrderedDict
import asyncpg
from fastapi import FastAPI, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import ORJSONResponse
from typing_extensions import Self
from utils.config import KanaeConfig
from fastapi.openapi.utils import get_openapi

if TYPE_CHECKING:
    from utils.request import RouteRequest


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
        self.add_exception_handler(
            RequestValidationError,
            self.request_validation_error_handler,  # type: ignore
        )

    ### Exception Handlers

    async def request_validation_error_handler(
        self, request: RouteRequest, exc: RequestValidationError
    ) -> ORJSONResponse:
        errors = ", ".join(
            OrderedDict.fromkeys(
                chain.from_iterable(exception["loc"] for exception in exc.errors())
            ).keys()
        )
        return ORJSONResponse(content=f"Field required at: {errors}", status_code=422)

    ### Server-related utilities

    @asynccontextmanager
    async def lifespan(self, app: Self):
        async with asyncpg.create_pool(dsn=self.config["postgres_uri"]) as app.pool:
            yield

    def get_db(self) -> Generator[asyncpg.Pool, None, None]:
        yield self.pool

    def openapi(self) -> dict[str, Any]:
        if not self.openapi_schema:
            self.openapi_schema = get_openapi(
                title=self.title,
                version=self.version,
                openapi_version=self.openapi_version,
                summary=self.summary,
                description=self.description,
                terms_of_service=self.terms_of_service,
                contact=self.contact,
                license_info=self.license_info,
                routes=self.routes,
                webhooks=self.webhooks.routes,
                tags=self.openapi_tags,
                servers=self.servers,
                separate_input_output_schemas=self.separate_input_output_schemas,
            )
            for path in self.openapi_schema["paths"].values():
                for method in path.values():
                    responses = method.get("responses")
                    if str(status.HTTP_422_UNPROCESSABLE_ENTITY) in responses:
                        del responses[str(status.HTTP_422_UNPROCESSABLE_ENTITY)]
        return self.openapi_schema
