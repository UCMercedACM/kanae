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

from starlette.routing import BaseRoute
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


import inspect

from fastapi import routing
from fastapi._compat import (
    GenerateJsonSchema,
    JsonSchemaValue,
    ModelField,
    get_compat_model_name_map,
    get_definitions,
    get_schema_from_model_field,
    lenient_issubclass,
)
from fastapi.datastructures import DefaultPlaceholder
from fastapi.dependencies.utils import (
    get_flat_dependant,
    get_flat_params,
)
from fastapi.encoders import jsonable_encoder
from fastapi.openapi.constants import METHODS_WITH_BODY, REF_PREFIX, REF_TEMPLATE
from fastapi.openapi.models import OpenAPI
from fastapi.types import ModelNameMap
from fastapi.utils import (
    deep_dict_update,
)
from starlette.responses import JSONResponse
from starlette.status import HTTP_422_UNPROCESSABLE_ENTITY
from typing_extensions import Literal

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


def get_openapi_path(
    *,
    route: routing.APIRoute,
    operation_ids: Set[str],
    schema_generator: GenerateJsonSchema,
    model_name_map: ModelNameMap,
    field_mapping: Dict[
        Tuple[ModelField, Literal["validation", "serialization"]], JsonSchemaValue
    ],
    separate_input_output_schemas: bool = True,
) -> Tuple[Dict[str, Any], Dict[str, Any], Dict[str, Any]]:
    path = {}
    security_schemes: Dict[str, Any] = {}
    definitions: Dict[str, Any] = {}
    assert route.methods is not None, "Methods must be a list"
    if isinstance(route.response_class, DefaultPlaceholder):
        current_response_class: Type[Response] = route.response_class.value
    else:
        current_response_class = route.response_class
    assert current_response_class, "A response class is needed to generate OpenAPI"
    route_response_media_type: Optional[str] = current_response_class.media_type
    if route.include_in_schema:
        for method in route.methods:
            operation = get_openapi_operation_metadata(
                route=route, method=method, operation_ids=operation_ids
            )
            parameters: List[Dict[str, Any]] = []
            flat_dependant = get_flat_dependant(route.dependant, skip_repeats=True)
            security_definitions, operation_security = get_openapi_security_definitions(
                flat_dependant=flat_dependant
            )
            if operation_security:
                operation.setdefault("security", []).extend(operation_security)
            if security_definitions:
                security_schemes.update(security_definitions)
            operation_parameters = _get_openapi_operation_parameters(
                dependant=route.dependant,
                schema_generator=schema_generator,
                model_name_map=model_name_map,
                field_mapping=field_mapping,
                separate_input_output_schemas=separate_input_output_schemas,
            )
            parameters.extend(operation_parameters)
            if parameters:
                all_parameters = {
                    (param["in"], param["name"]): param for param in parameters
                }
                required_parameters = {
                    (param["in"], param["name"]): param
                    for param in parameters
                    if param.get("required")
                }
                # Make sure required definitions of the same parameter take precedence
                # over non-required definitions
                all_parameters.update(required_parameters)
                operation["parameters"] = list(all_parameters.values())
            if method in METHODS_WITH_BODY:
                request_body_oai = get_openapi_operation_request_body(
                    body_field=route.body_field,
                    schema_generator=schema_generator,
                    model_name_map=model_name_map,
                    field_mapping=field_mapping,
                    separate_input_output_schemas=separate_input_output_schemas,
                )
                if request_body_oai:
                    operation["requestBody"] = request_body_oai
            if route.callbacks:
                callbacks = {}
                for callback in route.callbacks:
                    if isinstance(callback, routing.APIRoute):
                        (
                            cb_path,
                            cb_security_schemes,
                            cb_definitions,
                        ) = get_openapi_path(
                            route=callback,
                            operation_ids=operation_ids,
                            schema_generator=schema_generator,
                            model_name_map=model_name_map,
                            field_mapping=field_mapping,
                            separate_input_output_schemas=separate_input_output_schemas,
                        )
                        callbacks[callback.name] = {callback.path: cb_path}
                operation["callbacks"] = callbacks
            if route.status_code is not None:
                status_code = str(route.status_code)
            else:
                # It would probably make more sense for all response classes to have an
                # explicit default status_code, and to extract it from them, instead of
                # doing this inspection tricks, that would probably be in the future
                # TODO: probably make status_code a default class attribute for all
                # responses in Starlette
                response_signature = inspect.signature(current_response_class.__init__)
                status_code_param = response_signature.parameters.get("status_code")
                if status_code_param is not None:
                    if isinstance(status_code_param.default, int):
                        status_code = str(status_code_param.default)
            operation.setdefault("responses", {}).setdefault(status_code, {})[
                "description"
            ] = route.response_description
            if route_response_media_type and is_body_allowed_for_status_code(
                route.status_code
            ):
                response_schema = {"type": "string"}
                if lenient_issubclass(current_response_class, JSONResponse):
                    if route.response_field:
                        response_schema = get_schema_from_model_field(
                            field=route.response_field,
                            schema_generator=schema_generator,
                            model_name_map=model_name_map,
                            field_mapping=field_mapping,
                            separate_input_output_schemas=separate_input_output_schemas,
                        )
                    else:
                        response_schema = {}
                operation.setdefault("responses", {}).setdefault(
                    status_code, {}
                ).setdefault("content", {}).setdefault(route_response_media_type, {})[
                    "schema"
                ] = response_schema
            if route.responses:
                operation_responses = operation.setdefault("responses", {})
                for (
                    additional_status_code,
                    additional_response,
                ) in route.responses.items():
                    process_response = additional_response.copy()
                    process_response.pop("model", None)
                    status_code_key = str(additional_status_code).upper()
                    if status_code_key == "DEFAULT":
                        status_code_key = "default"
                    openapi_response = operation_responses.setdefault(
                        status_code_key, {}
                    )
                    assert isinstance(
                        process_response, dict
                    ), "An additional response must be a dict"
                    field = route.response_fields.get(additional_status_code)
                    additional_field_schema: Optional[Dict[str, Any]] = None
                    if field:
                        additional_field_schema = get_schema_from_model_field(
                            field=field,
                            schema_generator=schema_generator,
                            model_name_map=model_name_map,
                            field_mapping=field_mapping,
                            separate_input_output_schemas=separate_input_output_schemas,
                        )
                        media_type = route_response_media_type or "application/json"
                        additional_schema = (
                            process_response.setdefault("content", {})
                            .setdefault(media_type, {})
                            .setdefault("schema", {})
                        )
                        deep_dict_update(additional_schema, additional_field_schema)
                    status_text: Optional[str] = status_code_ranges.get(
                        str(additional_status_code).upper()
                    ) or http.client.responses.get(int(additional_status_code))
                    description = (
                        process_response.get("description")
                        or openapi_response.get("description")
                        or status_text
                        or "Additional Response"
                    )
                    deep_dict_update(openapi_response, process_response)
                    openapi_response["description"] = description
            http422 = str(HTTP_422_UNPROCESSABLE_ENTITY)
            all_route_params = get_flat_params(route.dependant)
            if (all_route_params or route.body_field) and not any(
                status in operation["responses"]
                for status in [http422, "4XX", "default"]
            ):
                operation["responses"][http422] = {
                    "description": "Validation Error",
                    "content": {
                        "application/json": {
                            "schema": {"$ref": REF_PREFIX + "HTTPValidationError"}
                        }
                    },
                }
                if "ValidationError" not in definitions:
                    definitions.update(
                        {
                            "ValidationError": validation_error_definition,
                            "HTTPValidationError": validation_error_response_definition,
                        }
                    )
            if route.openapi_extra:
                deep_dict_update(operation, route.openapi_extra)
            path[method.lower()] = operation
    return path, security_schemes, definitions


def get_openapi(
    *,
    title: str,
    version: str,
    openapi_version: str = "3.1.0",
    summary: Optional[str] = None,
    description: Optional[str] = None,
    routes: Sequence[BaseRoute],
    webhooks: Optional[Sequence[BaseRoute]] = None,
    tags: Optional[list[dict[str, Any]]] = None,
    servers: Optional[list[dict[str, Union[str, Any]]]] = None,
    terms_of_service: Optional[str] = None,
    contact: Optional[dict[str, Union[str, Any]]] = None,
    license_info: Optional[dict[str, Union[str, Any]]] = None,
    separate_input_output_schemas: bool = True,
) -> dict[str, Any]:
    info: dict[str, Any] = {"title": title, "version": version}
    if summary:
        info["summary"] = summary
    if description:
        info["description"] = description
    if terms_of_service:
        info["termsOfService"] = terms_of_service
    if contact:
        info["contact"] = contact
    if license_info:
        info["license"] = license_info
    output: dict[str, Any] = {"openapi": openapi_version, "info": info}
    if servers:
        output["servers"] = servers
    components: dict[str, dict[str, Any]] = {}
    paths: dict[str, dict[str, Any]] = {}
    webhook_paths: dict[str, dict[str, Any]] = {}
    operation_ids: set[str] = set()
    all_fields = get_fields_from_routes(list(routes or []) + list(webhooks or []))
    model_name_map = get_compat_model_name_map(all_fields)
    schema_generator = GenerateJsonSchema(ref_template=REF_TEMPLATE)
    field_mapping, definitions = get_definitions(
        fields=all_fields,
        schema_generator=schema_generator,
        model_name_map=model_name_map,
        separate_input_output_schemas=separate_input_output_schemas,
    )
    for route in routes or []:
        if isinstance(route, routing.APIRoute):
            result = get_openapi_path(
                route=route,
                operation_ids=operation_ids,
                schema_generator=schema_generator,
                model_name_map=model_name_map,
                field_mapping=field_mapping,
                separate_input_output_schemas=separate_input_output_schemas,
            )
            if result:
                path, security_schemes, path_definitions = result
                if path:
                    paths.setdefault(route.path_format, {}).update(path)
                if security_schemes:
                    components.setdefault("securitySchemes", {}).update(
                        security_schemes
                    )
                if path_definitions:
                    definitions.update(path_definitions)
    for webhook in webhooks or []:
        if isinstance(webhook, routing.APIRoute):
            result = get_openapi_path(
                route=webhook,
                operation_ids=operation_ids,
                schema_generator=schema_generator,
                model_name_map=model_name_map,
                field_mapping=field_mapping,
                separate_input_output_schemas=separate_input_output_schemas,
            )
            if result:
                path, security_schemes, path_definitions = result
                if path:
                    webhook_paths.setdefault(webhook.path_format, {}).update(path)
                if security_schemes:
                    components.setdefault("securitySchemes", {}).update(
                        security_schemes
                    )
                if path_definitions:
                    definitions.update(path_definitions)
    if definitions:
        components["schemas"] = {k: definitions[k] for k in sorted(definitions)}
    if components:
        output["components"] = components
    output["paths"] = paths
    if webhook_paths:
        output["webhooks"] = webhook_paths
    if tags:
        output["tags"] = tags
    return jsonable_encoder(OpenAPI(**output), by_alias=True, exclude_none=True)  # type: ignore


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
            # responses={400: {"model": RequestValidationErrorMessage}},
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
        #         # for path in self.openapi_schema["paths"].values():
        #         #     for method in path.values():
        #         #         responses = method.get("responses")
        #         #         if str(status.HTTP_422_UNPROCESSABLE_ENTITY) in responses:
        #         #             del responses[str(status.HTTP_422_UNPROCESSABLE_ENTITY)]
        return self.openapi_schema
