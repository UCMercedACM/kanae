from typing import TYPE_CHECKING, Any, Callable, Coroutine, List, Optional, Union
from urllib.parse import parse_qsl

from fastapi import Request
from supertokens_python.framework.request import BaseRequest
from supertokens_python.recipe.session.interfaces import SessionClaimValidator
from supertokens_python.recipe.session.recipe import SessionRecipe
from supertokens_python.types import MaybeAwaitable
from supertokens_python.utils import (
    set_request_in_user_context_if_not_defined,
)

from .session import PydanticSessionContainer

if TYPE_CHECKING:
    from fastapi import Request

# class KanaeSessionRecipe(SessionRecipe):

#     def __init__(self, *args, **kwargs):
#         super().__init__(*args, **kwargs)

#     @staticmethod
#     def init(
#         cookie_domain: Union[str, None] = None,
#         older_cookie_domain: Union[str, None] = None,
#         cookie_secure: Union[bool, None] = None,
#         cookie_same_site: Union[Literal["lax", "none", "strict"], None] = None,
#         session_expired_status_code: Union[int, None] = None,
#         anti_csrf: Union[
#             Literal["VIA_TOKEN", "VIA_CUSTOM_HEADER", "NONE"], None
#         ] = None,
#         get_token_transfer_method: Union[
#             Callable[
#                 [BaseRequest, bool, dict[str, Any]],
#                 Union[TokenTransferMethod, Literal["any"]],
#             ],
#             None,
#         ] = None,
#         error_handlers: Union[InputErrorHandlers, None] = None,
#         override: Union[InputOverrideConfig, None] = None,
#         invalid_claim_status_code: Union[int, None] = None,
#         use_dynamic_access_token_signing_key: Union[bool, None] = None,
#         expose_access_token_to_frontend_in_cookie_based_auth: Union[bool, None] = None,
#         jwks_refresh_interval_sec: Union[int, None] = None,
#     ):
#         def func(app_info: AppInfo):
#             if KanaeSessionRecipe.__instance is None:
#                 KanaeSessionRecipe.__instance = KanaeSessionRecipe(
#                     KanaeSessionRecipe.recipe_id,
#                     app_info,
#                     cookie_domain,
#                     older_cookie_domain,
#                     cookie_secure,
#                     cookie_same_site,
#                     session_expired_status_code,
#                     anti_csrf,
#                     get_token_transfer_method,
#                     error_handlers,
#                     override,
#                     invalid_claim_status_code,
#                     use_dynamic_access_token_signing_key,
#                     expose_access_token_to_frontend_in_cookie_based_auth,
#                     jwks_refresh_interval_sec,
#                 )
#                 return KanaeSessionRecipe.__instance
#             raise_general_exception(
#                 "Session recipe has already been initialised. Please check your code for bugs."
#             )

#         return func

#     async def verify_session(
#         self,
#         request: BaseRequest,
#         anti_csrf_check: Union[bool, None],
#         session_required: bool,
#         check_database: bool,
#         override_global_claim_validators: Optional[
#             Callable[
#                 [list[SessionClaimValidator], PydanticSessionContainer, dict[str, Any]],
#                 MaybeAwaitable[list[SessionClaimValidator]],
#             ]
#         ],
#         user_context: dict[str, Any],
#     ) ->Self:
#         _ = user_context

#         return await self.api_implementation.verify_session(
#             APIOptions(
#                 request,
#                 None,
#                 self.recipe_id,
#                 self.config,
#                 self.recipe_implementation,
#             ),
#             anti_csrf_check,
#             session_required,
#             check_database,
#             override_global_claim_validators,
#             user_context,
#         )


class KanaeOverrideRequest(BaseRequest):
    def __init__(self, request: Request):
        super().__init__()
        self.request = request

    def get_original_url(self) -> str:
        return self.request.url.components.geturl()

    def get_query_param(
        self, key: str, default: Union[str, None] = None
    ) -> Union[str, None]:
        return self.request.query_params.get(key, default)

    def get_query_params(self) -> dict[str, Any]:
        return dict(self.request.query_params.items())

    async def json(self) -> Union[Any, None]:
        try:
            return await self.request.json()
        except Exception:
            return {}

    def method(self) -> str:
        return self.request.method

    def get_cookie(self, key: str) -> Union[str, None]:
        # Note: Unlike other frameworks, FastAPI wraps the value in quotes in Set-Cookie header
        # It also takes care of escaping the quotes while fetching the value
        return self.request.cookies.get(key)

    def get_header(self, key: str) -> Union[str, None]:
        return self.request.headers.get(key, None)

    def get_session(self) -> Union[PydanticSessionContainer, None]:
        return self.request.state.supertokens

    def set_session(self, session: PydanticSessionContainer):
        self.request.state.supertokens = session

    def set_session_as_none(self):
        self.request.state.supertokens = None

    def get_path(self) -> str:
        root_path = self.request.scope.get("root_path")
        if root_path is None:
            raise Exception("should never happen")

        url = self.request.url.path
        # FastAPI seems buggy and it adds an extra root_path (if it matches):
        # So we trim the extra root_path (from the left) from the url
        return url[url.startswith(root_path) and len(root_path) :]

    async def form_data(self):
        return dict(parse_qsl((await self.request.body()).decode("utf-8")))


def verify_session(
    anti_csrf_check: Union[bool, None] = None,
    session_required: bool = True,
    check_database: bool = False,
    override_global_claim_validators: Optional[
        Callable[
            [List[SessionClaimValidator], PydanticSessionContainer, dict[str, Any]],
            MaybeAwaitable[List[SessionClaimValidator]],
        ]
    ] = None,
    user_context: Union[None, dict[str, Any]] = None,
) -> Callable[..., Coroutine[Any, Any, Union[PydanticSessionContainer, None]]]:
    _ = user_context

    async def func(request: Request) -> Union[PydanticSessionContainer, None]:
        nonlocal user_context
        base_req = KanaeOverrideRequest(request)
        user_context = set_request_in_user_context_if_not_defined(
            user_context, base_req
        )

        recipe = SessionRecipe.get_instance()
        session = await recipe.verify_session(
            base_req,
            anti_csrf_check,
            session_required,
            check_database,
            override_global_claim_validators,  # type: ignore
            user_context,
        )
        if session is None:
            if session_required:
                raise Exception("Should never come here")
            base_req.set_session_as_none()
        else:
            base_req.set_session(session)  # type: ignore
        return base_req.get_session()

    return func


# async def session_exception_handler(
#     request: Request, exc: SuperTokensError
# ) -> JSONResponse:
#     """FastAPI exceptional handler for errors raised by Supertokens SDK when not using middleware

#     Usage: `app.add_exception_handler(SuperTokensError, st_exception_handler)`
#     """
#     base_req = FastApiRequest(request)
#     base_res = FastApiResponse(JSONResponse(content={}))
#     user_context = default_user_context(base_req)
#     result = await Supertokens.get_instance().handle_supertokens_error(
#         base_req, exc, base_res, user_context
#     )
#     if isinstance(result, FastApiResponse):
#         body = json.loads(bytes(result.response.body))
#         return JSONResponse(body, status_code=result.response.status_code)

#     raise Exception("Should never come here")
