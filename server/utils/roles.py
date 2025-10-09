# Current scopes:
# read:
#   all
#   projects
#   events
#   tags
# write:
#   all
#   events
#   projects
# ---------------
# And current roles: admin, leads
import functools
import inspect
from typing import Any, Callable, Coroutine, Optional, TypeVar

from supertokens_python.exceptions import GeneralError
from supertokens_python.recipe.session import SessionContainer
from supertokens_python.recipe.session.exceptions import (
    ClaimValidationError,
    InvalidClaimsError,
)
from supertokens_python.recipe.userroles import UserRoleClaim

T = TypeVar("T")

Coro = Coroutine[Any, Any, T]
CoroFunc = Callable[..., Coro[Any]]


def validate_parameters(func: CoroFunc):
    sig = inspect.signature(func)
    if not sig.parameters.get("session"):
        raise GeneralError(
            f"No <session> argument found within function <{func.__name__}>"
        )


def has_role(item: str, /):
    def decorator(func: CoroFunc) -> CoroFunc:
        validate_parameters(func)

        @functools.wraps(func)
        async def wrapper(
            session: Optional[SessionContainer], *args, **kwargs
        ) -> CoroFunc:
            if not session:
                raise GeneralError("Must have valid session")

            roles = await session.get_claim_value(UserRoleClaim)
            if not roles or item not in roles:
                raise InvalidClaimsError(
                    f"User does not have role <{item}>",
                    [ClaimValidationError(UserRoleClaim.key, None)],
                )

            return await func(*args, **kwargs)

        return wrapper

    return decorator


def has_any_role(*items: str):
    def decorator(func: CoroFunc) -> CoroFunc:
        validate_parameters(func)

        @functools.wraps(func)
        async def wrapper(
            session: Optional[SessionContainer], *args, **kwargs
        ) -> CoroFunc:
            if not session:
                raise GeneralError("Must have valid session")

            user_roles = await session.get_claim_value(UserRoleClaim)

            if not user_roles:
                missing_roles = ", ".join(role for role in items)
                raise InvalidClaimsError(
                    f"User does not any roles listed: {missing_roles.rstrip()}",
                    [ClaimValidationError(UserRoleClaim.key, None)],
                )
            if not any(role in user_roles for role in items):
                # May need to be tested more
                raise InvalidClaimsError(
                    f"Missing Roles: {', '.join(role for role in items if role not in user_roles).rstrip()}",
                    [ClaimValidationError(UserRoleClaim.key, None)],
                )

            return await func(*args, **kwargs)

        return wrapper

    return decorator


def has_admin_role():
    return has_role("admin")


def has_leads_role():
    return has_role("leads")
