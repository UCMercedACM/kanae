from __future__ import annotations

import asyncio
from collections import OrderedDict
from contextlib import asynccontextmanager
from itertools import chain
from typing import TYPE_CHECKING, Any, Generator, Optional

import asyncpg
from fastapi import FastAPI, status
from fastapi.exceptions import RequestValidationError
from fastapi.openapi.utils import get_openapi
from fastapi.responses import ORJSONResponse
from typing_extensions import Self
from utils.config import KanaeConfig

from server import __description__, __title__, __version__

if TYPE_CHECKING:
    from utils.request import RouteRequest


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
            title=__title__,
            description=__description__,
            vesrion=__version__,
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
                description=self.description,
                terms_of_service=self.terms_of_service,
                contact=self.contact,
                license_info=self.license_info,
                routes=self.routes,
                tags=self.openapi_tags,
                servers=self.servers,
            )
            for path in self.openapi_schema["paths"].values():
                for method in path.values():
                    responses = method.get("responses")
                    if str(status.HTTP_422_UNPROCESSABLE_ENTITY) in responses:
                        del responses[str(status.HTTP_422_UNPROCESSABLE_ENTITY)]
        return self.openapi_schema
