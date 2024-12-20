from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import TYPE_CHECKING, Any, Generator, Optional, Self

import asyncpg
from fastapi import Depends, FastAPI, status
from fastapi.exceptions import HTTPException, RequestValidationError
from fastapi.openapi.utils import get_openapi
from fastapi.responses import ORJSONResponse, Response
from fastapi.utils import is_body_allowed_for_status_code
from supertokens_python import (
    InputAppInfo,
    SupertokensConfig,
    init as supertokens_init,
)
from supertokens_python.recipe import passwordless, session, thirdparty
from supertokens_python.recipe.passwordless import ContactEmailOnlyConfig
from supertokens_python.recipe.thirdparty.provider import (
    ProviderClientConfig,
    ProviderConfig,
    ProviderInput,
)
from utils.config import KanaeConfig
from utils.errors import (
    HTTPExceptionMessage,
    RequestValidationErrorDetails,
    RequestValidationErrorMessage,
)

if TYPE_CHECKING:
    from utils.request import RouteRequest


__title__ = "Kanae"
__description__ = """
Kanae is ACM @ UC Merced's API.

This document details the API as it is right now. 
Changes can be made without notification, but announcements will be made for major changes. 
"""
__version__ = "0.1.0a"


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
            version=__version__,
            dependencies=[Depends(self.get_db)],
            default_response_class=ORJSONResponse,
            responses={400: {"model": RequestValidationErrorMessage}},
            loop=self.loop,
            redoc_url="/docs",
            docs_url=None,
            lifespan=self.lifespan,
        )
        supertokens_init(
            app_info=InputAppInfo(
                app_name="ucmacm-website",
                api_domain=config["auth"]["api_domain"],
                website_domain=config["auth"]["website_domain"],
                api_base_path="/api-auth",
                website_base_path="/auth",
            ),
            supertokens_config=SupertokensConfig(
                connection_uri=config["auth"]["connection_uri"]
            ),
            framework="fastapi",
            recipe_list=[
                session.init(),
                thirdparty.init(
                    sign_in_and_up_feature=thirdparty.SignInAndUpFeature(
                        providers=[
                            ProviderInput(
                                config=ProviderConfig(
                                    third_party_id="google",
                                    clients=[
                                        ProviderClientConfig(
                                            client_id=config["auth"]["providers"][
                                                "google"
                                            ]["client_id"],
                                            client_secret=config["auth"]["providers"][
                                                "google"
                                            ]["client_secret"],
                                        ),
                                    ],
                                ),
                            ),
                            ProviderInput(
                                config=ProviderConfig(
                                    third_party_id="github",
                                    clients=[
                                        ProviderClientConfig(
                                            client_id=config["auth"]["providers"][
                                                "github"
                                            ]["client_id"],
                                            client_secret=config["auth"]["providers"][
                                                "github"
                                            ]["client_secret"],
                                        ),
                                    ],
                                ),
                            ),
                        ]
                    )
                ),
                passwordless.init(
                    flow_type="USER_INPUT_CODE", contact_config=ContactEmailOnlyConfig()
                ),
            ],
            mode="asgi",
        )
        self.config = config
        self.add_exception_handler(
            HTTPException,
            self.http_exception_handler,  # type: ignore
        )
        self.add_exception_handler(
            RequestValidationError,
            self.request_validation_error_handler,  # type: ignore
        )

    ### Exception Handlers

    async def http_exception_handler(
        self, request: RouteRequest, exc: HTTPException
    ) -> Response:
        headers = getattr(exc, "headers", None)
        if not is_body_allowed_for_status_code(exc.status_code):
            return Response(status_code=exc.status_code, headers=headers)
        message = HTTPExceptionMessage(detail=exc.detail)
        return ORJSONResponse(
            content=message.model_dump(), status_code=exc.status_code, headers=headers
        )

    async def request_validation_error_handler(
        self, request: RouteRequest, exc: RequestValidationError
    ) -> ORJSONResponse:
        message = RequestValidationErrorMessage(
            errors=[
                RequestValidationErrorDetails(
                    detail=exception["msg"], context=exception["ctx"]["error"]
                )
                for exception in exc.errors()
            ]
        )

        return ORJSONResponse(
            content=message.model_dump(), status_code=status.HTTP_400_BAD_REQUEST
        )

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
