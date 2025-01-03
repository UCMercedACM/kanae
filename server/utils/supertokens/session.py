from __future__ import annotations

from abc import ABC, abstractmethod
from typing import (
    TYPE_CHECKING,
    Any,
    Callable,
    Dict,
    Generic,
    List,
    Literal,
    Optional,
    TypeVar,
    Union,
)

from supertokens_python.async_to_sync_wrapper import sync
from supertokens_python.normalised_url_path import (
    NormalisedURLPath,
    normalise_url_path_or_throw_error,
)
from supertokens_python.recipe.session.interfaces import (
    GetSessionTokensDangerouslyDict,
    JSONObject,
    ReqResInfo,
    ResponseMutator,
    SessionClaim,
    SessionClaimValidator,
    TokenInfo,
)
from supertokens_python.recipe.session.utils import (
    ErrorHandlers,
    OverrideConfig,
    TokenTransferMethod,
)
from supertokens_python.types import (
    RecipeUserId,
)

if TYPE_CHECKING:
    from supertokens_python.framework import BaseRequest

from pydantic import BaseModel

_T = TypeVar("_T")


class SessionDoesNotExistError:
    pass


class GetClaimValueOkResult(Generic[_T]):
    def __init__(self, value: Optional[_T]):
        self.value = value


class PydanticRecipeInterface(BaseModel, ABC):  # pylint: disable=too-many-public-methods
    def __init__(self):
        pass


class OverrideNormalisedURLPath(BaseModel, NormalisedURLPath):
    __value: str

    def __init__(self, url: str):
        self.__value = normalise_url_path_or_throw_error(url)

    def startswith(self, other: NormalisedURLPath) -> bool:
        return self.__value.startswith(other.get_as_string_dangerous())

    def append(self, other: NormalisedURLPath) -> NormalisedURLPath:
        return NormalisedURLPath(self.__value + other.get_as_string_dangerous())

    def get_as_string_dangerous(self) -> str:
        return self.__value

    def equals(self, other: NormalisedURLPath) -> bool:
        return self.__value == other.get_as_string_dangerous()

    def is_a_recipe_path(self) -> bool:
        parts = self.__value.split("/")
        return parts[1] == "recipe" or (len(parts) > 2 and parts[2] == "recipe")


class PydanticSessionConfig(BaseModel):
    refresh_token_path: OverrideNormalisedURLPath
    cookie_domain: Union[None, str]
    older_cookie_domain: Union[None, str]
    get_cookie_same_site: Callable[
        [Optional[BaseRequest], Dict[str, Any]],
        Literal["lax", "strict", "none"],
    ]
    cookie_secure: bool
    session_expired_status_code: int
    error_handlers: ErrorHandlers
    anti_csrf_function_or_string: Union[
        Callable[
            [Optional[BaseRequest], Dict[str, Any]],
            Literal["VIA_CUSTOM_HEADER", "NONE"],
        ],
        Literal["VIA_CUSTOM_HEADER", "NONE", "VIA_TOKEN"],
    ]
    get_token_transfer_method: Callable[
        [BaseRequest, bool, Dict[str, Any]],
        Union[TokenTransferMethod, Literal["any"]],
    ]
    override: OverrideConfig
    framework: str
    mode: str
    invalid_claim_status_code: int
    use_dynamic_access_token_signing_key: bool
    expose_access_token_to_frontend_in_cookie_based_auth: bool
    jwks_refresh_interval_sec: int


class PydanticSessionContainer(BaseModel, ABC):  # pylint: disable=too-many-public-methods
    recipe_implementation: PydanticRecipeInterface
    config: PydanticSessionConfig
    access_token: str
    front_token: str
    refresh_token: Optional[TokenInfo]
    anti_csrf_token: Optional[str]
    session_handle: str
    user_id: str
    recipe_user_id: RecipeUserId
    user_data_in_access_token: Optional[dict[str, Any]]
    req_res_info: Optional[ReqResInfo]
    access_token_updated: bool
    tenant_id: str
    response_mutators: list[ResponseMutator] = []

    # def __init__(
    #     self,
    #     recipe_implementation: RecipeInterface,
    #     config: SessionConfig,
    #     access_token: str,
    #     front_token: str,
    #     refresh_token: Optional[TokenInfo],
    #     anti_csrf_token: Optional[str],
    #     session_handle: str,
    #     user_id: str,
    #     recipe_user_id: RecipeUserId,
    #     user_data_in_access_token: Optional[dict[str, Any]],
    #     req_res_info: Optional[ReqResInfo],
    #     access_token_updated: bool,
    #     tenant_id: str,
    # ):
    #     self.recipe_implementation = recipe_implementation
    #     self.config = config
    #     self.access_token = access_token
    #     self.front_token = front_token
    #     self.refresh_token = refresh_token
    #     self.anti_csrf_token = anti_csrf_token
    #     self.session_handle = session_handle
    #     self.user_id = user_id
    #     self.recipe_user_id = recipe_user_id
    #     self.user_data_in_access_token = user_data_in_access_token
    #     self.req_res_info: Optional[ReqResInfo] = req_res_info
    #     self.access_token_updated = access_token_updated
    #     self.tenant_id = tenant_id
    #     self.response_mutators: List[ResponseMutator] = []

    @abstractmethod
    async def revoke_session(
        self, user_context: Optional[dict[str, Any]] = None
    ) -> None:
        pass

    @abstractmethod
    async def get_session_data_from_database(
        self, user_context: Optional[dict[str, Any]] = None
    ) -> dict[str, Any]:
        pass

    @abstractmethod
    async def update_session_data_in_database(
        self,
        new_session_data: dict[str, Any],
        user_context: Optional[dict[str, Any]] = None,
    ) -> None:
        pass

    @abstractmethod
    async def attach_to_request_response(
        self,
        request: BaseRequest,
        transfer_method: TokenTransferMethod,
        user_context: dict[str, Any],
    ):
        pass

    @abstractmethod
    async def merge_into_access_token_payload(
        self,
        access_token_payload_update: JSONObject,
        user_context: Optional[dict[str, Any]] = None,
    ) -> None:
        pass

    @abstractmethod
    def get_user_id(self, user_context: Optional[dict[str, Any]] = None) -> str:
        pass

    @abstractmethod
    def get_recipe_user_id(
        self, user_context: Optional[dict[str, Any]] = None
    ) -> RecipeUserId:
        pass

    @abstractmethod
    def get_tenant_id(self, user_context: Optional[dict[str, Any]] = None) -> str:
        pass

    @abstractmethod
    def get_access_token_payload(
        self, user_context: Optional[dict[str, Any]] = None
    ) -> dict[str, Any]:
        pass

    @abstractmethod
    def get_handle(self, user_context: Optional[dict[str, Any]] = None) -> str:
        pass

    @abstractmethod
    def get_all_session_tokens_dangerously(self) -> GetSessionTokensDangerouslyDict:
        pass

    @abstractmethod
    def get_access_token(self, user_context: Optional[dict[str, Any]] = None) -> str:
        pass

    @abstractmethod
    async def get_time_created(
        self, user_context: Optional[dict[str, Any]] = None
    ) -> int:
        pass

    @abstractmethod
    async def get_expiry(self, user_context: Optional[dict[str, Any]] = None) -> int:
        pass

    @abstractmethod
    async def assert_claims(
        self,
        claim_validators: List[SessionClaimValidator],
        user_context: Optional[dict[str, Any]] = None,
    ) -> None:
        pass

    @abstractmethod
    async def fetch_and_set_claim(
        self, claim: SessionClaim[Any], user_context: Optional[dict[str, Any]] = None
    ) -> None:
        pass

    @abstractmethod
    async def set_claim_value(
        self,
        claim: SessionClaim[_T],
        value: _T,
        user_context: Optional[dict[str, Any]] = None,
    ) -> None:
        pass

    @abstractmethod
    async def get_claim_value(
        self, claim: SessionClaim[_T], user_context: Optional[dict[str, Any]] = None
    ) -> Union[_T, None]:
        pass

    @abstractmethod
    async def remove_claim(
        self,
        claim: SessionClaim[Any],
        user_context: Optional[dict[str, Any]] = None,
    ) -> None:
        pass

    def sync_get_expiry(self, user_context: Optional[dict[str, Any]] = None) -> int:
        return sync(self.get_expiry(user_context))

    def sync_revoke_session(
        self, user_context: Optional[dict[str, Any]] = None
    ) -> None:
        return sync(self.revoke_session(user_context=user_context))

    def sync_get_session_data_from_database(
        self, user_context: Union[dict[str, Any], None] = None
    ) -> dict[str, Any]:
        return sync(self.get_session_data_from_database(user_context))

    def sync_get_time_created(
        self, user_context: Optional[dict[str, Any]] = None
    ) -> int:
        return sync(self.get_time_created(user_context))

    def sync_merge_into_access_token_payload(
        self,
        access_token_payload_update: dict[str, Any],
        user_context: Optional[dict[str, Any]] = None,
    ) -> None:
        return sync(
            self.merge_into_access_token_payload(
                access_token_payload_update, user_context
            )
        )

    def sync_update_session_data_in_database(
        self,
        new_session_data: dict[str, Any],
        user_context: Optional[dict[str, Any]] = None,
    ) -> None:
        return sync(
            self.update_session_data_in_database(new_session_data, user_context)
        )

    # Session claims sync functions:
    def sync_assert_claims(
        self,
        claim_validators: List[SessionClaimValidator],
        user_context: Optional[dict[str, Any]] = None,
    ) -> None:
        return sync(self.assert_claims(claim_validators, user_context))

    def sync_fetch_and_set_claim(
        self, claim: SessionClaim[Any], user_context: Optional[dict[str, Any]] = None
    ) -> None:
        return sync(self.fetch_and_set_claim(claim, user_context))

    def sync_set_claim_value(
        self,
        claim: SessionClaim[_T],
        value: _T,
        user_context: Optional[dict[str, Any]] = None,
    ) -> None:
        return sync(self.set_claim_value(claim, value, user_context))

    def sync_get_claim_value(
        self, claim: SessionClaim[_T], user_context: Optional[dict[str, Any]] = None
    ) -> Union[_T, None]:
        return sync(self.get_claim_value(claim, user_context))

    def sync_remove_claim(
        self, claim: SessionClaim[Any], user_context: Optional[dict[str, Any]] = None
    ) -> None:
        return sync(self.remove_claim(claim, user_context))

    def sync_attach_to_request_response(
        self,
        request: BaseRequest,
        transfer_method: TokenTransferMethod,
        user_context: dict[str, Any],
    ) -> None:
        return sync(
            self.attach_to_request_response(request, transfer_method, user_context)
        )

    # This is there so that we can do session["..."] to access some of the members of this class
    def __getitem__(self, item: str):
        return getattr(self, item)


# class RecipeInterface(BaseModel, ABC):  # pylint: disable=too-many-public-methods
#     @abstractmethod
#     async def create_new_session(
#         self,
#         user_id: str,
#         recipe_user_id: RecipeUserId,
#         access_token_payload: Optional[Dict[str, Any]],
#         session_data_in_database: Optional[Dict[str, Any]],
#         disable_anti_csrf: Optional[bool],
#         tenant_id: str,
#         user_context: Dict[str, Any],
#     ) -> PydanticSessionContainer:
#         pass

#     @abstractmethod
#     def get_global_claim_validators(
#         self,
#         tenant_id: str,
#         user_id: str,
#         recipe_user_id: RecipeUserId,
#         claim_validators_added_by_other_recipes: List[SessionClaimValidator],
#         user_context: Dict[str, Any],
#     ) -> MaybeAwaitable[List[SessionClaimValidator]]:
#         pass

#     @abstractmethod
#     async def get_session(
#         self,
#         access_token: Optional[str],
#         anti_csrf_token: Optional[str] = None,
#         anti_csrf_check: Optional[bool] = None,
#         session_required: Optional[bool] = None,
#         check_database: Optional[bool] = None,
#         override_global_claim_validators: Optional[
#             Callable[
#                 [List[SessionClaimValidator], PydanticSessionContainer, Dict[str, Any]],
#                 MaybeAwaitable[List[SessionClaimValidator]],
#             ]
#         ] = None,
#         user_context: Optional[Dict[str, Any]] = None,
#     ) -> Optional[PydanticSessionContainer]:
#         pass

#     @abstractmethod
#     async def validate_claims(
#         self,
#         user_id: str,
#         recipe_user_id: RecipeUserId,
#         access_token_payload: Dict[str, Any],
#         claim_validators: List[SessionClaimValidator],
#         user_context: Dict[str, Any],
#     ) -> ClaimsValidationResult:
#         pass

#     @abstractmethod
#     async def refresh_session(
#         self,
#         refresh_token: str,
#         anti_csrf_token: Optional[str],
#         disable_anti_csrf: bool,
#         user_context: Dict[str, Any],
#     ) -> PydanticSessionContainer:
#         pass

#     @abstractmethod
#     async def revoke_session(
#         self, session_handle: str, user_context: Dict[str, Any]
#     ) -> bool:
#         pass

#     @abstractmethod
#     async def revoke_all_sessions_for_user(
#         self,
#         user_id: str,
#         revoke_sessions_for_linked_accounts: bool,
#         tenant_id: str,
#         revoke_across_all_tenants: bool,
#         user_context: Dict[str, Any],
#     ) -> List[str]:
#         pass

#     @abstractmethod
#     async def get_all_session_handles_for_user(
#         self,
#         user_id: str,
#         fetch_sessions_for_linked_accounts: bool,
#         tenant_id: str,
#         fetch_across_all_tenants: bool,
#         user_context: Dict[str, Any],
#     ) -> List[str]:
#         pass

#     @abstractmethod
#     async def revoke_multiple_sessions(
#         self, session_handles: List[str], user_context: Dict[str, Any]
#     ) -> List[str]:
#         pass

#     @abstractmethod
#     async def get_session_information(
#         self, session_handle: str, user_context: Dict[str, Any]
#     ) -> Union[SessionInformationResult, None]:
#         pass

#     @abstractmethod
#     async def update_session_data_in_database(
#         self,
#         session_handle: str,
#         new_session_data: Dict[str, Any],
#         user_context: Dict[str, Any],
#     ) -> bool:
#         pass

#     @abstractmethod
#     async def merge_into_access_token_payload(
#         self,
#         session_handle: str,
#         access_token_payload_update: JSONObject,
#         user_context: Dict[str, Any],
#     ) -> bool:
#         pass

#     @abstractmethod
#     async def fetch_and_set_claim(
#         self,
#         session_handle: str,
#         claim: SessionClaim[Any],
#         user_context: Dict[str, Any],
#     ) -> bool:
#         pass

#     @abstractmethod
#     async def set_claim_value(
#         self,
#         session_handle: str,
#         claim: SessionClaim[_T],
#         value: _T,
#         user_context: Dict[str, Any],
#     ) -> bool:
#         pass

#     @abstractmethod
#     async def get_claim_value(
#         self,
#         session_handle: str,
#         claim: SessionClaim[Any],
#         user_context: Dict[str, Any],
#     ) -> Union[SessionDoesNotExistError, GetClaimValueOkResult[Any]]:
#         pass

#     @abstractmethod
#     async def remove_claim(
#         self,
#         session_handle: str,
#         claim: SessionClaim[Any],
#         user_context: Dict[str, Any],
#     ) -> bool:
#         pass

#     @abstractmethod
#     async def regenerate_access_token(
#         self,
#         access_token: str,
#         new_access_token_payload: Union[Dict[str, Any], None],
#         user_context: Dict[str, Any],
#     ) -> Union[RegenerateAccessTokenOkResult, None]:
#         pass
