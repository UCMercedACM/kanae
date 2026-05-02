from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import TYPE_CHECKING, Any, Self

import aiohttp
import asyncpg
import orjson
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from fastapi import Depends, FastAPI, status
from fastapi.exceptions import HTTPException, RequestValidationError
from fastapi.openapi.utils import get_openapi
from fastapi.responses import Response
from fastapi.utils import is_body_allowed_for_status_code
from utils.glide import GlideManager
from utils.limiter.extension import (
    KanaeLimiter,
    RateLimitExceeded,
    rate_limit_exceeded_handler,
)
from utils.ory import OryClient
from utils.prometheus import InstrumentatorSettings, PrometheusInstrumentator
from utils.responses.exceptions import (
    HTTPExceptionResponse,
    RequestValidationErrorResponse,
)
from utils.responses.orjson import ORJSONResponse

if TYPE_CHECKING:
    from collections.abc import AsyncGenerator, Generator

    from utils.config import KanaeConfig
    from utils.request import RouteRequest


__title__ = "Kanae"
__description__ = """
Kanae is ACM @ UC Merced's API.

This document details the API as it is right now.
Changes can be made without notification, but announcements will be made for major changes.
"""
__version__ = "0.1.0"


async def init(conn: asyncpg.Connection) -> None:
    # Refer to https://github.com/MagicStack/asyncpg/issues/140#issuecomment-301477123
    def _encode_jsonb(value: Any) -> bytes:  # noqa: ANN401
        return b"\x01" + orjson.dumps(value)

    def _decode_jsonb(value: bytes) -> Any:  # noqa: ANN401
        return orjson.loads(value[1:].decode("utf-8"))

    await conn.set_type_codec(
        "jsonb",
        schema="pg_catalog",
        encoder=_encode_jsonb,
        decoder=_decode_jsonb,
        format="binary",
    )


### FastAPI subclass (Kanae)
class Kanae(FastAPI):
    pool: asyncpg.Pool
    session: aiohttp.ClientSession
    glide: GlideManager

    limiter: KanaeLimiter
    ory: OryClient

    def __init__(
        self,
        *,
        config: KanaeConfig,
    ) -> None:
        super().__init__(
            title=__title__,
            description=__description__,
            version=__version__,
            dependencies=[Depends(self.get_db)],
            default_response_class=ORJSONResponse,
            http="httptools",
            responses={400: {"model": RequestValidationErrorResponse}},
            redoc_url="/docs",
            docs_url=None,
            lifespan=self.lifespan,
        )

        self._logger = logging.getLogger("kanae.core")

        self.config = config
        self.is_prometheus_enabled: bool = config.kanae.prometheus["enabled"]

        _instrumentator_settings = InstrumentatorSettings(metric_namespace="kanae")
        self.instrumentator = PrometheusInstrumentator(
            self, settings=_instrumentator_settings
        )

        self.ph = PasswordHasher()

        self.add_exception_handler(
            HTTPException,
            self.http_exception_handler,  # ty: ignore[invalid-argument-type]
        )
        self.add_exception_handler(
            RequestValidationError,
            self.request_validation_error_handler,  # ty: ignore[invalid-argument-type]
        )
        self.add_exception_handler(
            VerificationError,
            self.verification_error_handler,  # ty: ignore[invalid-argument-type]
        )
        self.add_exception_handler(
            RateLimitExceeded,
            rate_limit_exceeded_handler,  # ty: ignore[invalid-argument-type]
        )

        if self.is_prometheus_enabled:
            _host = self.config.kanae.prometheus["host"]
            _port = self.config.kanae.prometheus["port"]

            self.instrumentator.start()

            self._logger.info(
                "Prometheus server started on %s:%d/metrics", _host, _port
            )

    ### Exception Handlers

    def http_exception_handler(
        self, request: RouteRequest, exc: HTTPException
    ) -> Response:
        headers = getattr(exc, "headers", None)
        if not is_body_allowed_for_status_code(exc.status_code):
            return Response(status_code=exc.status_code, headers=headers)
        message = HTTPExceptionResponse(detail=exc.detail)
        return ORJSONResponse(
            content=message.model_dump(), status_code=exc.status_code, headers=headers
        )

    def request_validation_error_handler(
        self, request: RouteRequest, exc: RequestValidationError
    ) -> Response:
        # The errors seem to be extremely inconsistent
        # For now, we'll log them down for further analysis
        errors = exc.errors()
        message = RequestValidationErrorResponse(errors=errors)
        self._logger.warning("Request Validation Error! Message:\n%s", errors)
        return ORJSONResponse(
            content=message.model_dump(),
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
        )

    def verification_error_handler(
        self, request: RouteRequest, exc: VerificationError
    ) -> ORJSONResponse:
        return ORJSONResponse(
            content={"error": "Failed to verify, entirely invalid hash"},
            status_code=status.HTTP_403_FORBIDDEN,
        )

    ### Server-related utilities

    @asynccontextmanager
    async def lifespan(self, app: Self) -> AsyncGenerator[None]:
        async with (
            asyncpg.create_pool(dsn=self.config.postgres_uri, init=init) as app.pool,
            aiohttp.ClientSession() as app.session,  # ty: ignore[invalid-assignment]
            GlideManager(uri=app.limiter.storage_uri) as app.glide,
        ):
            app.ory = OryClient(self.config.ory, session=app.session, glide=app.glide)
            app.limiter.attach(app.glide)

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
