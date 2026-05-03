from __future__ import annotations

from typing import TYPE_CHECKING

from fastapi import HTTPException

from .responses import HTTP_404_DETAIL

if TYPE_CHECKING:
    from collections.abc import Sequence

    from .checks import CheckContext, CheckPredicate, ResourcePermission, Role


class BaseHTTPException(HTTPException):
    status_code: int

    def __init__(self, detail: str) -> None:
        self.detail = detail


# HTTP 400
class BadRequestError(BaseHTTPException):
    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.status_code = 400


# HTTP 401
class UnauthorizedError(BaseHTTPException):
    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.status_code = 401


# HTTP 403
class ForbiddenError(BaseHTTPException):
    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.status_code = 403


# HTTP 404
class NotFoundError(BaseHTTPException):
    def __init__(self, detail: str = HTTP_404_DETAIL) -> None:
        super().__init__(detail)
        self.status_code = 404


# HTTP 409
class ConflictError(BaseHTTPException):
    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.status_code = 409


# HTTP 502
class BadGatewayError(BaseHTTPException):
    def __init__(self, detail: str = "Upstream rejected the request") -> None:
        super().__init__(detail)
        self.status_code = 502


# HTTP 503
class ServiceUnavailableError(BaseHTTPException):
    def __init__(self, detail: str = "Authentication service unavailable") -> None:
        super().__init__(detail)
        self.status_code = 503


### Check errors


class CheckFailure(ForbiddenError):
    """Base class for check-related failures.

    All exceptions raised by `check`, `check_any`, and the higher-level
    factories descend from this. Inherits from `ForbiddenError` so a single
    FastAPI exception handler registered for the HTTP base catches every variant.
    """


class CheckAnyFailure[ContextT: CheckContext](CheckFailure):
    """Exception raised when all predicates in `check_any` fail.

    Mirrors `discord.ext.commands.CheckAnyFailure`.

    Attributes:
        checks (list[CheckPredicate[ContextT]]): The check predicates that all failed.
        errors (list[CheckFailure]): The individual failures caught while running the predicates.
    """

    def __init__(
        self, checks: list[CheckPredicate[ContextT]], errors: list[CheckFailure]
    ) -> None:
        self.checks: list[CheckPredicate[ContextT]] = checks
        self.errors: list[CheckFailure] = errors

        super().__init__(detail="All checks have failed")


class MissingRole(CheckFailure):
    """Exception raised when the caller lacks a role to run a command.

    Mirrors `discord.ext.commands.MissingRole`.

    Attributes:
        missing_role (Role): The required role that is missing. This is the parameter
            passed to `has_role`.
    """

    def __init__(self, missing_role: Role) -> None:
        self.missing_role: Role = missing_role
        message = f"Role {missing_role!r} is required to run this command."
        super().__init__(message)


class MissingAnyRole(CheckFailure):
    """Exception raised when the caller lacks any of the roles specified.

    Mirrors `discord.ext.commands.MissingAnyRole`.

    Attributes:
        missing_roles (list[Role]): The roles that the caller is missing. These are the
            parameters passed to `has_any_role`.
    """

    def __init__(self, missing_roles: list[Role]) -> None:
        self.missing_roles: list[Role] = missing_roles

        missing = [f"'{role}'" for role in missing_roles]
        fmt = ", ".join(missing)
        message = f"You are missing at least one of the required roles: {fmt}"
        super().__init__(message)


class MissingPermissions(CheckFailure):
    """Exception raised when the caller lacks permissions to access a resource.

    Mirrors `discord.ext.commands.MissingPermissions`.

    Attributes:
        missing_permissions (list[ResourcePermission]): The required permissions that are missing. These
            are the parameters passed to `has_permissions`.
    """

    def __init__(
        self, missing_permissions: list[ResourcePermission], *args: object
    ) -> None:
        self.missing_permissions: list[ResourcePermission] = missing_permissions

        missing = [
            f"{perm.resource.namespace}:{perm.relation}" for perm in missing_permissions
        ]

        fmt = self._human_join(missing, final="and")
        message = f"You are missing {fmt} permission(s) to access this resource."
        super().__init__(message, *args)

    def _human_join(
        self, seq: Sequence[str], /, *, delimiter: str = ", ", final: str = "or"
    ) -> str:
        size = len(seq)
        if size == 0:
            return ""

        if size == 1:
            return seq[0]

        if size == 2:
            return f"{seq[0]} {final} {seq[1]}"

        return delimiter.join(seq[:-1]) + f" {final} {seq[-1]}"
