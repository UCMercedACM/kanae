from __future__ import annotations

import logging
import re
import sys
from contextlib import asynccontextmanager
from typing import TYPE_CHECKING, Any, Generator, NamedTuple, Optional, Union

import asyncpg
import orjson
import yarl
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from email_validator import EmailNotValidError, validate_email
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
from supertokens_python.auth_utils import (
    LinkingToSessionUserFailedError,  # type: ignore
)
from supertokens_python.exceptions import GeneralError
from supertokens_python.recipe import (
    dashboard,
    emailpassword,
    session,
    thirdparty,
    userroles,
)
from supertokens_python.recipe.emailpassword import InputFormField
from supertokens_python.recipe.session.interfaces import SessionContainer
from supertokens_python.types.base import AccountInfoInput

# isort: off
# isort is turned off here to clarify the different imports of interfaces and providers
from supertokens_python.recipe.thirdparty.interfaces import (
    APIInterface as ThirdPartyAPIInterface,
    APIOptions as ThirdPartyAPIOptions,
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
from supertokens_python.recipe.thirdparty.api.implementation import (
    APIImplementation as ThirdPartyAPIImplementation,
)
from supertokens_python.recipe.thirdparty.recipe_implementation import (
    RecipeImplementation as ThirdPartyRecipeImplementation,
)

from supertokens_python.recipe.emailpassword.interfaces import (
    EmailAlreadyExistsError,
    APIInterface as EmailPasswordAPIInterface,
    APIOptions as EmailPasswordAPIOptions,
    RecipeInterface as EmailPasswordInterface,
    SignUpOkResult as EmailPasswordSignUpOkResult,
    SignUpPostOkResult as EmailPasswordSignUpPostOkResult,
)
from supertokens_python.recipe.emailpassword.api.implementation import (
    APIImplementation as EmailPasswordAPIImplementation,
)
from supertokens_python.recipe.emailpassword.recipe_implementation import (
    RecipeImplementation as EmailPasswordImplementation,
)

from supertokens_python.recipe.userroles.asyncio import (
    create_new_role_or_add_permissions,
    get_all_roles,
)
# isort: on

from supertokens_python.normalised_url_domain import NormalisedURLDomain
from supertokens_python.normalised_url_path import NormalisedURLPath
from supertokens_python.querier import Querier
from supertokens_python.supertokens import Host
from supertokens_python.types import GeneralErrorResponse
from utils.config import KanaeConfig
from utils.limiter.extension import RateLimitExceeded, rate_limit_exceeded_handler
from utils.prometheus import InstrumentatorSettings, PrometheusInstrumentator
from utils.responses.exceptions import (
    HTTPExceptionResponse,
    RequestValidationErrorResponse,
)

if sys.version_info >= (3, 11):
    from typing import Self, Unpack
else:
    from typing_extensions import Self, Unpack

if TYPE_CHECKING:
    from supertokens_python.recipe.emailpassword.types import FormField
    from supertokens_python.recipe.thirdparty.types import (
        RawUserInfoFromProvider,
        ThirdPartyInfo,
    )
    from utils.request import RouteRequest


__title__ = "Kanae"
__description__ = """
Kanae is ACM @ UC Merced's API.

This document details the API as it is right now. 
Changes can be made without notification, but announcements will be made for major changes. 
"""
__version__ = "0.1.0a"

EMAIL_INVALID_MESSAGE = "Email provided is invalid"


ThirdPartyResultType = Union[
    LinkingToSessionUserFailedError,
    ThirdPartySignInUpOkResult,
    ThirdPartySignInUpNotAllowed,
]
EmailResultType = Union[
    LinkingToSessionUserFailedError,
    EmailPasswordSignUpOkResult,
    EmailPasswordSignUpPostOkResult,
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


### Customized versions of third party and email+password implementations


class SupertokensQuerier(Querier):
    def __init__(self, recipe_id: str, *, config: KanaeConfig):
        super().__init__(
            self._get_normalized_host_supertokens(config["auth"]["connection_uri"]),
            recipe_id,
        )

        # Why is it necessary to call an `init` method and then a `get_instance` method just to get the instance?????
        # Just buggy behavior...
        self.disable_init_called()

    @staticmethod
    def disable_init_called() -> None:
        # This has to be done in a static method as the variable is with the class, not instance. Similar to C/C++
        SupertokensQuerier.__init_called = True

    def _get_normalized_host_supertokens(self, hosts: list[str]) -> list[Host]:
        def _build_url(host: str) -> Host:
            url = yarl.URL(host)

            if not url.host:
                raise ValueError("No host found in supertokens URL")

            domain = NormalisedURLDomain(
                str(yarl.URL.build(scheme=url.scheme, host=url.host, port=url.port))
            )
            path = NormalisedURLPath(url.path_safe)

            return Host(domain, path)

        return [_build_url(host) for host in hosts]


class ThirdPartyHandler(ThirdPartyRecipeImplementation):
    RECIPE_ID = "thirdparty"

    def __init__(self, app: Kanae, config: KanaeConfig):
        self.app = app
        self.querier = SupertokensQuerier(self.RECIPE_ID, config=config)

    async def _register(
        self,
        third_party_id: str,
        third_party_user_id: str,
        email: str,
        is_verified: bool,
        oauth_tokens: dict[str, Any],
        raw_user_info_from_provider: RawUserInfoFromProvider,
        session: Optional[SessionContainer],
        should_try_linking_with_session_user: Optional[bool],
        tenant_id: str,
        user_context: dict[str, Any],
    ) -> Union[
        ThirdPartySignInUpOkResult,
        ThirdPartySignInUpNotAllowed,
        LinkingToSessionUserFailedError,
        GeneralErrorResponse,
    ]:
        existing_users = await list_users_by_account_info(
            tenant_id, AccountInfoInput(email=email)
        )
        if len(existing_users) == 0:
            result = await self.sign_in_up(
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

            if isinstance(result, ThirdPartySignInUpOkResult):
                user_info = result.raw_user_info_from_provider.from_user_info_api
                if (
                    user_info
                    and result.created_new_recipe_user
                    and len(result.user.login_methods) == 1
                ):
                    is_valid_email = validate_email(
                        user_info["email"], check_deliverability=True, strict=True
                    )
                    if isinstance(is_valid_email, EmailNotValidError):
                        raise EmailNotValidError(EMAIL_INVALID_MESSAGE)

                    normalized_email = is_valid_email.normalized
                    await self.app._set_first_time_member(
                        result.user.id, user_info["name"], normalized_email
                    )
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
            result = await self.sign_in_up(
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
            return result

        raise GeneralError("Cannot sign up as email already exists")

    def override_sign_in_up(
        self, implementation: ThirdPartyRecipeInterface
    ) -> ThirdPartyRecipeInterface:
        implementation.sign_in_up = self._register  # type: ignore
        return implementation


class ThirdPartyAPIHandler(ThirdPartyAPIImplementation):
    async def _post_register(
        self,
        provider: Provider,
        redirect_uri_info: Optional[RedirectUriInfo],
        oauth_tokens: Optional[dict[str, Any]],
        session: Optional[SessionContainer],
        should_try_linking_with_session_user: Optional[bool],
        tenant_id: str,
        api_options: ThirdPartyAPIOptions,
        user_context: dict[str, Any],
    ):
        try:
            return await self.sign_in_up_post(
                provider,
                redirect_uri_info,
                oauth_tokens,
                session,
                should_try_linking_with_session_user,
                tenant_id,
                api_options,
                user_context,
            )
        except GeneralError:
            return GeneralErrorResponse(
                "Seems like you already have an account with another social login provider. Please use that instead."
            )

    def override_post_register(
        self, implementation: ThirdPartyAPIInterface
    ) -> ThirdPartyAPIInterface:
        implementation.sign_in_up_post = self._post_register
        return implementation


class EmailPasswordHandler(EmailPasswordImplementation):
    RECIPE_ID = "emailpassword"

    def __init__(self, app: Kanae, config: KanaeConfig):
        self.app = app
        self.querier = SupertokensQuerier(self.RECIPE_ID, config=config)

    async def _register(
        self,
        email: str,
        password: str,
        tenant_id: str,
        session: Optional[SessionContainer],
        should_try_linking_with_session_user: Optional[bool],
        user_context: dict[str, Any],
    ):
        is_valid_email = validate_email(email, check_deliverability=True, strict=True)
        if isinstance(is_valid_email, EmailNotValidError):
            raise EmailNotValidError(EMAIL_INVALID_MESSAGE)

        normalized_email = is_valid_email.normalized
        existing_users = await list_users_by_account_info(
            tenant_id, AccountInfoInput(email=normalized_email)
        )

        if len(existing_users) == 0:
            # this means this email is new so we allow sign up
            result = await self.sign_up(
                normalized_email,
                password,
                tenant_id,
                session,
                should_try_linking_with_session_user,
                user_context,
            )

            if isinstance(result, EmailPasswordSignUpOkResult):
                await self.app._set_first_time_member(
                    result.user.id, normalized_email, normalized_email
                )

            return result

        return EmailAlreadyExistsError()

    def override_sign_up(
        self, implementation: EmailPasswordInterface
    ) -> EmailPasswordInterface:
        implementation.sign_up = self._register
        return implementation


class UserFields(NamedTuple):
    name: str
    email: str


class EmailPasswordAPIHandler(EmailPasswordAPIImplementation):
    def __init__(self, app: Kanae):
        self.app = app
        self.validate_name_regex = re.compile(r"^[-\w\s]+$")

    async def _post_register(
        self,
        form_fields: list[FormField],
        tenant_id: str,
        session: Optional[SessionContainer],
        should_try_linking_with_session_user: Optional[bool],
        api_options: EmailPasswordAPIOptions,
        user_context: dict[str, Any],
    ):
        result = await self.sign_up_post(
            form_fields,
            tenant_id,
            session,
            should_try_linking_with_session_user,
            api_options,
            user_context,
        )

        if isinstance(result, EmailPasswordSignUpPostOkResult):
            user_fields = UserFields(
                *(
                    field.value
                    for field in form_fields
                    if field.id == "name" or field.id == "email"
                )
            )

            is_valid_email = validate_email(
                user_fields.email, check_deliverability=True, strict=True
            )
            if isinstance(is_valid_email, EmailNotValidError):
                raise EmailNotValidError(EMAIL_INVALID_MESSAGE)

            normalized_email = is_valid_email.normalized

            await self.app._set_first_time_member(
                result.user.id, user_fields.name, normalized_email
            )

        return result

    async def validate_name(self, value: str, tenant_id: str) -> Optional[str]:
        if self.validate_name_regex.fullmatch(value):
            return

        return "Invalid name detected"

    def override_post_register(
        self, implementation: EmailPasswordAPIInterface
    ) -> EmailPasswordAPIInterface:
        implementation.sign_up_post = self._post_register

        return implementation


### FastAPI subclass (Kanae)
class Kanae(FastAPI):
    pool: asyncpg.Pool

    def __init__(
        self,
        *,
        config: KanaeConfig,
    ):
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

        _tp_handler = ThirdPartyHandler(self, config)
        _ep_handler = EmailPasswordHandler(self, config)
        _tp_api_handler = ThirdPartyAPIHandler()
        _ep_api_handler = EmailPasswordAPIHandler(self)

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
                        apis=_tp_api_handler.override_post_register,
                        functions=_tp_handler.override_sign_in_up,
                    ),
                ),
                emailpassword.init(
                    sign_up_feature=emailpassword.InputSignUpFeature(
                        form_fields=[
                            InputFormField(
                                id="name", validate=_ep_api_handler.validate_name
                            ),
                        ]
                    ),
                    override=emailpassword.InputOverrideConfig(
                        functions=_ep_handler.override_sign_up,
                        apis=_ep_api_handler.override_post_register,
                    ),
                ),
                dashboard.init(),
                userroles.init(),
            ],
            mode="asgi",
        )

        self._logger = logging.getLogger("kanae.core")

        self.config = config
        self.is_prometheus_enabled: bool = config["kanae"]["prometheus"]["enabled"]

        _instrumentator_settings = InstrumentatorSettings(metric_namespace="kanae")
        self.instrumentator = PrometheusInstrumentator(
            self, settings=_instrumentator_settings
        )

        self.ph = PasswordHasher()

        self.add_exception_handler(
            HTTPException,
            self.http_exception_handler,  # type: ignore
        )
        self.add_exception_handler(
            RequestValidationError,
            self.request_validation_error_handler,  # type: ignore
        )
        self.add_exception_handler(
            GeneralError,
            self.general_error_handler,  # type: ignore
        )
        self.add_exception_handler(
            VerificationError,
            self.verification_error_handler,  # type: ignore
        )
        self.add_exception_handler(
            RateLimitExceeded,
            rate_limit_exceeded_handler,  # type: ignore
        )
        self.add_exception_handler(
            EmailNotValidError,
            self.email_invalid_error_handler,  # type: ignore
        )

        if self.is_prometheus_enabled:
            _host = self.config["kanae"]["host"]
            _port = self.config["kanae"]["port"]

            self.instrumentator.start()

            self._logger.info(
                "Prometheus server started on %s:%d/metrics", _host, _port
            )

    # SuperTokens related utils

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
                    reason="RECIPE_USER_ID_ALREADY_LINKED_WITH_ANOTHER_PRIMARY_USER_ID_ERROR"
                )
            except Exception as e:
                await tr.rollback()
                return GeneralErrorResponse(str(e))
            else:
                await tr.commit()
                return

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
    ) -> ORJSONResponse:
        # The errors seem to be extremely inconsistent
        # For now, we'll log them down for further analysis
        encoded = orjson.dumps(exc.errors()).decode("utf-8")
        message = RequestValidationErrorResponse(errors=encoded)
        self._logger.warning("Request Validation Error! Message:\n%s", encoded)
        return ORJSONResponse(
            content=message.model_dump(), status_code=status.HTTP_400_BAD_REQUEST
        )

    def general_error_handler(
        self, request: RouteRequest, exc: GeneralError
    ) -> ORJSONResponse:
        return ORJSONResponse(
            content={"error": str(exc)}, status_code=status.HTTP_400_BAD_REQUEST
        )

    def verification_error_handler(
        self, request: RouteRequest, exc: VerificationError
    ) -> ORJSONResponse:
        return ORJSONResponse(
            content={"error": "Failed to verify, entirely invalid hash"},
            status_code=status.HTTP_403_FORBIDDEN,
        )

    def email_invalid_error_handler(
        self, request: RouteRequest, exc: EmailNotValidError
    ) -> ORJSONResponse:
        return ORJSONResponse(
            content={"error": "Invalid email address"},
            status_code=status.HTTP_400_BAD_REQUEST,
        )

    ### Server-related utilities

    @asynccontextmanager
    async def lifespan(self, app: Self):
        all_roles = await get_all_roles()

        if not all_roles.roles:
            # Create the roles if we don't have them, alongside the permissions
            await create_new_role_or_add_permissions("admin", ["read_all", "write_all"])
            await create_new_role_or_add_permissions(
                "leads", ["read_projects", "read_events", "write_events"]
            )

        async with asyncpg.create_pool(
            dsn=self.config["postgres_uri"], init=init
        ) as app.pool:
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
