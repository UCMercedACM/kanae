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
from __future__ import annotations

import functools
import inspect
from collections.abc import Callable, Coroutine
from typing import TYPE_CHECKING, Optional, ParamSpec, TypeVar

from supertokens_python.exceptions import GeneralError
from supertokens_python.recipe.session.exceptions import (
    ClaimValidationError,
    InvalidClaimsError,
)
from supertokens_python.recipe.userroles import UserRoleClaim

if TYPE_CHECKING:
    from supertokens_python.recipe.session import SessionContainer

T = TypeVar("T")
P = ParamSpec("P")

Coro = Coroutine[None, None, T]
CoroFunc = Callable[P, Coro[T]]


def validate_parameters(func: Callable[..., object]) -> None:
    sig = inspect.signature(func)
    if not sig.parameters.get("session"):
        msg = f"No <session> argument found within function <{func.__name__}>"
        raise GeneralError(msg)


def has_role(item: str, /) -> Callable[[CoroFunc[P, T]], CoroFunc[P, T]]:
    def decorator(func: CoroFunc[P, T]) -> CoroFunc[P, T]:
        validate_parameters(func)

        @functools.wraps(func)
        async def wrapper(
            *args: P.args,
            **kwargs: P.kwargs,
        ) -> T:
            session: Optional[SessionContainer] = kwargs.get("session")  # type: ignore[assignment]
            if not session:
                msg = "Must have valid session"
                raise GeneralError(msg)

            roles = await session.get_claim_value(UserRoleClaim)
            if not roles or item not in roles:
                msg = f"User does not have role <{item}>"
                raise InvalidClaimsError(
                    msg,
                    [ClaimValidationError(UserRoleClaim.key, None)],
                )

            return await func(*args, **kwargs)

        return wrapper

    return decorator


def has_any_role(*items: str) -> Callable[[CoroFunc[P, T]], CoroFunc[P, T]]:
    def decorator(func: CoroFunc[P, T]) -> CoroFunc[P, T]:
        validate_parameters(func)

        @functools.wraps(func)
        async def wrapper(
            *args: P.args,
            **kwargs: P.kwargs,
        ) -> T:
            session: Optional[SessionContainer] = kwargs.get("session")  # type: ignore[assignment]
            if not session:
                msg = "Must have valid session"
                raise GeneralError(msg)

            user_roles = await session.get_claim_value(UserRoleClaim)

            if not user_roles:
                missing_roles = ", ".join(role for role in items)
                msg = f"User does not any roles listed: {missing_roles.rstrip()}"
                raise InvalidClaimsError(
                    msg,
                    [ClaimValidationError(UserRoleClaim.key, None)],
                )
            if not any(role in user_roles for role in items):
                # May need to be tested more
                msg = f"Missing Roles: {', '.join(role for role in items if role not in user_roles).rstrip()}"
                raise InvalidClaimsError(
                    msg,
                    [ClaimValidationError(UserRoleClaim.key, None)],
                )

            return await func(*args, **kwargs)

        return wrapper

    return decorator


def has_admin_role() -> Callable[[CoroFunc[P, T]], CoroFunc[P, T]]:
    return has_role("admin")


def has_leads_role() -> Callable[[CoroFunc[P, T]], CoroFunc[P, T]]:
    return has_role("leads")
