from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import TYPE_CHECKING, Any, Generator, Optional, Self, Union, Unpack

import asyncpg
import orjson
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
from supertokens_python.asyncio import list_users_by_account_info
from supertokens_python.auth_utils import LinkingToSessionUserFailedError
from supertokens_python.recipe import dashboard, emailpassword, session, thirdparty
from supertokens_python.recipe.session.interfaces import SessionContainer

# isort: off
# isort is turned off here to clarify the different imports of interfaces and providers
from supertokens_python.recipe.thirdparty.interfaces import (
    APIInterface,
    APIOptions,
    RecipeInterface as ThirdPartyRecipeInterface,
    SignInUpNotAllowed as ThirdPartySignInUpNotAllowed,
    SignInUpOkResult as ThirdPartySignInUpOkResult,
)
from supertokens_python.recipe.thirdparty.provider import (
    Provider,
    ProviderClientConfig,
    ProviderConfig,
    ProviderInput,
    RedirectUriInfo,
)
from supertokens_python.recipe.emailpassword.interfaces import (
    EmailAlreadyExistsError,
    RecipeInterface as EmailPasswordRecipeInterface,
    SignUpOkResult as EmailPasswordSignUpOkResult,
)
# isort: on

from utils.config import KanaeConfig
from utils.errors import (
    HTTPExceptionMessage,
    RequestValidationErrorDetails,
    RequestValidationErrorMessage,
)

if TYPE_CHECKING:
    from supertokens_python.recipe.thirdparty.types import (
        RawUserInfoFromProvider,
        ThirdPartyInfo,
    )
    from supertokens_python.types import AccountInfo, GeneralErrorResponse
    from utils.request import RouteRequest


__title__ = "Kanae"
__description__ = """
Kanae is ACM @ UC Merced's API.

This document details the API as it is right now. 
Changes can be made without notification, but announcements will be made for major changes. 
"""
__version__ = "0.1.0a"


ThirdPartyResultType = Union[
    LinkingToSessionUserFailedError,
    ThirdPartySignInUpOkResult,
    ThirdPartySignInUpNotAllowed,
]
EmailResultType = Union[
    LinkingToSessionUserFailedError,
    EmailPasswordSignUpOkResult,
    EmailAlreadyExistsError,
]

async def init(conn: asyncpg.Connection):
    # Refer to https://github.com/MagicStack/asyncpg/issues/140#issuecomment-301477123
    def _encode_jsonb(value):
        return b"\x01" + orjson.dumps(value)

    def _decode_jsonb(value):
        return orjson.loads(value[1:].decode("utf-8"))

    await conn.set_type_codec(
        "jsonb",
        schema="pg_catalog",
        encoder=_encode_jsonb,
        decoder=_decode_jsonb,
        format="binary",
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
                api_base_path="/auth",
                website_base_path="/auth",
            ),
            supertokens_config=SupertokensConfig(
                connection_uri=config["auth"]["connection_uri"],
                api_key=config["auth"]["api_key"],
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
                                            scope=config["auth"]["providers"]["google"][
                                                "scopes"
                                            ],
                                        ),
                                    ],
                                ),
                            )
                        ]
                    ),
                    override=thirdparty.InputOverrideConfig(
                        functions=self.third_party_override
                    ),
                ),
                emailpassword.init(
                    override=emailpassword.InputOverrideConfig(
                        functions=self.emailpassword_override
                    )
                ),
                dashboard.init(),
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

    # SuperTokens recipes overrides

    # This is taken from the docs and modified
    def third_party_override(
        self, original_implementation: ThirdPartyRecipeInterface
    ) -> ThirdPartyRecipeInterface:
        original_sign_in_up = original_implementation.sign_in_up

        async def sign_in_up(
            third_party_id: str,
            third_party_user_id: str,
            email: str,
            is_verified: bool,
            oauth_tokens: dict[str, Any],
            raw_user_info_from_provider: RawUserInfoFromProvider,
            session: Optional[SessionContainer],
            should_try_linking_with_session_user: Union[bool, None],
            tenant_id: str,
            user_context: dict[str, Any],
        ):
            existing_users = await list_users_by_account_info(
                tenant_id, AccountInfo(email=email)
            )
            if len(existing_users) == 0:
                result = await original_sign_in_up(
                    third_party_id,
                    third_party_user_id,
                    email,
                    is_verified,
                    oauth_tokens,
                    raw_user_info_from_provider,
                    session,
                    should_try_linking_with_session_user,
                    tenant_id,
                    user_context,
                )
                await self._first_time_tp_sign_up(result)
                return result

            if any(
                any(
                    lm.recipe_id == "thirdparty"
                    and lm.has_same_third_party_info_as(
                        ThirdPartyInfo(third_party_user_id, third_party_id)
                    )
                    for lm in user.login_methods
                )
                for user in existing_users
            ):
                result = await original_sign_in_up(
                    third_party_id,
                    third_party_user_id,
                    email,
                    is_verified,
                    oauth_tokens,
                    raw_user_info_from_provider,
                    session,
                    should_try_linking_with_session_user,
                    tenant_id,
                    user_context,
                )
                await self._first_time_tp_sign_up(result)
                return result

            raise RuntimeError("Cannot sign up as email already exists")

        original_implementation.sign_in_up = sign_in_up

        return original_implementation

    def emailpassword_override(
        self,
        original_implementation: EmailPasswordRecipeInterface,
    ) -> EmailPasswordRecipeInterface:
        original_email_password_sign_up = original_implementation.sign_up

        async def emailpassword_sign_up(
            email: str,
            password: str,
            tenant_id: str,
            session: Union[SessionContainer, None],
            should_try_linking_with_session_user: Union[bool, None],
            user_context: dict[str, Any],
        ):
            existing_users = await list_users_by_account_info(
                tenant_id, AccountInfo(email=email)
            )

            if len(existing_users) == 0:
                # this means this email is new so we allow sign up
                result = await original_email_password_sign_up(
                    email,
                    password,
                    tenant_id,
                    session,
                    should_try_linking_with_session_user,
                    user_context,
                )

                if isinstance(result, EmailPasswordSignUpOkResult):
                    await self._set_first_time_member(result.user.id, email, email)

                return result

            return EmailAlreadyExistsError()

        original_implementation.sign_up = emailpassword_sign_up

        return original_implementation

    def apis_override(self, original_implementation: APIInterface) -> APIInterface:
        original_sign_in_up_post = original_implementation.sign_in_up_post

        async def sign_in_up_post(
            provider: Provider,
            redirect_uri_info: Optional[RedirectUriInfo],
            oauth_tokens: Optional[dict[str, Any]],
            session: Optional[SessionContainer],
            should_try_linking_with_session_user: Union[bool, None],
            tenant_id: str,
            api_options: APIOptions,
            user_context: dict[str, Any],
        ):
            try:
                return await original_sign_in_up_post(
                    provider,
                    redirect_uri_info,
                    oauth_tokens,
                    session,
                    should_try_linking_with_session_user,
                    tenant_id,
                    api_options,
                    user_context,
                )
            except Exception as e:
                if str(e) == "Cannot sign up as email already exists":
                    return GeneralErrorResponse(
                        "Seems like you already have an account with another social login provider. Please use that instead."
                    )
                raise e

        original_implementation.sign_in_up_post = sign_in_up_post
        return original_implementation

    async def _first_time_tp_sign_up(
        self, result: ThirdPartyResultType
    ) -> Union[ThirdPartyResultType, GeneralErrorResponse]:
        if isinstance(result, ThirdPartySignInUpOkResult):
            user_info = result.raw_user_info_from_provider.from_user_info_api
            if (
                user_info
                and result.created_new_recipe_user
                and len(result.user.login_methods) == 1
            ):
                await self._set_first_time_member(
                    result.user.id, user_info["name"], user_info["email"]
                )

        return result

    async def _set_first_time_member(
        self, id: str, *args: Unpack[tuple[str, str]]
    ) -> Union[ThirdPartyResultType, EmailResultType, GeneralErrorResponse, None]:
        query = """
        INSERT INTO members (id, name, email)
        VALUES ($1, $2, $3);
        """
        async with self.pool.acquire() as connection:
            tr = connection.transaction()
            await tr.start()
            try:
                await connection.execute(query, id, *args)
            except asyncpg.UniqueViolationError:
                await tr.rollback()
                return LinkingToSessionUserFailedError(
                    "RECIPE_USER_ID_ALREADY_LINKED_WITH_ANOTHER_PRIMARY_USER_ID_ERROR"
                )
            except Exception as e:
                await tr.rollback()
                return GeneralErrorResponse(str(e))
            else:
                await tr.commit()
                return

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
                    detail=exception["msg"], context="yee"
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
        async with asyncpg.create_pool(dsn=self.config["postgres_uri"], init=init) as app.pool:
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
