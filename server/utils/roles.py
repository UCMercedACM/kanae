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
from collections.abc import Callable, Coroutine
from typing import TYPE_CHECKING, cast

from supertokens_python.exceptions import GeneralError
from supertokens_python.recipe.session.exceptions import (
    ClaimValidationError,
    InvalidClaimsError,
)
from supertokens_python.recipe.userroles import UserRoleClaim

if TYPE_CHECKING:
    from supertokens_python.recipe.session import SessionContainer

type Coro[T] = Coroutine[None, None, T]
type CoroFunc[**P, T] = Callable[P, Coro[T]]


def validate_parameters(func: Callable[..., object]) -> None:
    sig = inspect.signature(func)
    if not sig.parameters.get("session"):
        msg = f"No <session> argument found within function <{func.__name__}>"  # ty: ignore[unresolved-attribute]
        raise GeneralError(msg)


def has_role[**P, T](item: str, /) -> Callable[[CoroFunc[P, T]], CoroFunc[P, T]]:
    def decorator(func: CoroFunc[P, T]) -> CoroFunc[P, T]:
        validate_parameters(func)

        @functools.wraps(func)
        async def wrapper(
            *args: P.args,
            **kwargs: P.kwargs,
        ) -> T:
            session = cast("SessionContainer | None", kwargs.get("session"))
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

            return await func(*args, **kwargs)  # ty: ignore[invalid-return-type,invalid-argument-type]

        return wrapper  # ty: ignore[invalid-return-type]

    return decorator  # ty: ignore[invalid-return-type]


def has_any_role[**P, T](*items: str) -> Callable[[CoroFunc[P, T]], CoroFunc[P, T]]:
    def decorator(func: CoroFunc[P, T]) -> CoroFunc[P, T]:
        validate_parameters(func)

        @functools.wraps(func)
        async def wrapper(
            *args: P.args,
            **kwargs: P.kwargs,
        ) -> T:
            session = cast("SessionContainer | None", kwargs.get("session"))
            if not session:
                msg = "Must have valid session"
                raise GeneralError(msg)

            user_roles = await session.get_claim_value(UserRoleClaim)

            if not user_roles:
                missing_roles = ", ".join(items)
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

            return await func(*args, **kwargs)  # ty: ignore[invalid-return-type,invalid-argument-type]

        return wrapper  # ty: ignore[invalid-return-type]

    return decorator  # ty: ignore[invalid-return-type]


def has_admin_role[**P, T]() -> Callable[[CoroFunc[P, T]], CoroFunc[P, T]]:
    return has_role("admin")


def has_leads_role[**P, T]() -> Callable[[CoroFunc[P, T]], CoroFunc[P, T]]:
    return has_role("leads")
