import uuid
from collections.abc import Awaitable, Callable, Iterable
from enum import StrEnum
from typing import Annotated, Literal, NamedTuple, Protocol

from fastapi import Depends
from fastapi.params import Depends as _Depends

from utils.auth import use_session
from utils.errors import ForbiddenError
from utils.ory import KanaeSession, OryClient
from utils.request import RouteRequest

from .errors import (
    CheckAnyFailure,
    CheckFailure,
    MissingAnyRole,
    MissingPermissions,
    MissingRole,
)

### Types


_PermissionNamespace = Literal["Project", "Event", "Member"]
_PermissionRelation = Literal["view", "edit", "own"]

type CheckPredicate[ContextT] = Callable[[ContextT], Awaitable[bool]]


class Check[ContextT](Protocol):
    predicate: CheckPredicate[ContextT]


class Role(StrEnum):
    ADMIN = "admin"
    MANAGER = "manager"
    LEADS = "leads"


### Structs


class ResourcePermission(NamedTuple):
    resource: "Resource"
    relation: _PermissionRelation


class CheckContext:
    __slots__ = ("request", "session")

    def __init__(self, request: RouteRequest, session: KanaeSession) -> None:
        self.request = request
        self.session = session

    @property
    def ory(self) -> OryClient:
        return self.request.app.ory


### Internal utilities


async def _async_any(awaitables: Iterable[Awaitable[bool]]) -> bool:
    for aw in awaitables:
        if await aw:
            return True
    return False


### Resources


class Resource:
    """A namespaced resource with three pre-built permission accessors.

    Each `Resource` declares its Keto namespace name once and the URL path
    parameter that carries the resource UUID. The three permits (`view`,
    `edit`, `own`) are populated as `ResourcePermission` instances at
    construction time, so call sites read naturally as `Project.edit`,
    `Event.own`, etc.

    Attributes:
        namespace (_PermissionRelation): The Keto namespace this resource maps to (e.g. `"Project"`).
        path_parameter (str): The FastAPI path parameter name carrying the resource
            UUID (e.g. `"project_id"`). Used by `has_permission` to look up
            the resource id from `request.path_params`.
        view (ResourcePermission): The `view` permission for this resource.
        edit (ResourcePermission): The `edit` permission for this resource.
        own (ResourcePermission): The `own` permission for this resource.
    """

    __slots__ = ("edit", "namespace", "own", "path_parameter", "view")

    def __init__(self, namespace: _PermissionNamespace, *, path_parameter: str) -> None:
        self.namespace = namespace
        self.view = ResourcePermission(self, "view")
        self.edit = ResourcePermission(self, "edit")
        self.own = ResourcePermission(self, "own")
        self.path_parameter = path_parameter


Project = Resource("Project", path_parameter="project_id")
Event = Resource("Event", path_parameter="event_id")
Member = Resource("Member", path_parameter="member_id")

### Core dependency overriding logic


class CheckDependency[ContextT: CheckContext](_Depends):
    """Concrete FastAPI dependency wrapping a check predicate.

    Subclass of `fastapi.params.Depends`, so instances plug directly into
    `dependencies=[...]`. Each instance carries a single predicate exposed
    via the `predicate` attribute - this is what lets higher-level
    combinators like `check_any` introspect and recompose checks rather
    than re-running the entire dependency chain per inner check.

    Attributes:
        predicate (CheckPredicate): The async predicate invoked when the dependency fires.
            Receives a `CheckContext` and returns `True` (pass) or
            `False` (raises a generic `ForbiddenError`). Predicates
            may also raise `CheckFailure` or a subclass directly to surface
            a more specific failure.
    """

    def __init__(self, predicate: CheckPredicate) -> None:
        self.predicate: CheckPredicate = predicate

        super().__init__(dependency=self._check)

    async def _check(
        self,
        request: RouteRequest,
        session: Annotated[KanaeSession, Depends(use_session)],
    ) -> None:
        ctx = CheckContext(request=request, session=session)
        pred = await self.predicate(ctx)

        if not pred:
            msg = "check failed"
            raise ForbiddenError(msg)


### Check functions


def check[ContextT: CheckContext](
    predicate: CheckPredicate[ContextT],
) -> CheckDependency[ContextT]:
    """Wrap a `(ctx) -> bool` predicate into a composable check.

    Mirrors `discord.ext.commands.check`. The return is the concrete
    `CheckDependency` so it plugs directly into FastAPI's
    `dependencies=[...]`; the `Check` Protocol describes its contract for
    parameters that should accept any check (see `check_any`).

    Args:
        predicate (CheckPredicate[ContextT]): An async callable taking a `CheckContext` and returning a
            bool. May raise `CheckFailure` (or a subclass) directly to surface
            a more specific failure than the generic deny.

    Returns:
        CheckDependency: A `CheckDependency` ready to drop into `dependencies=[...]`.
    """
    return CheckDependency(predicate)


def check_any[ContextT: CheckContext](
    *checks: Check[ContextT],
) -> CheckDependency[ContextT]:
    """Pass if any of the supplied checks pass (logical OR).

    If all checks fail, `CheckAnyFailure` is raised carrying the individual
    failures.

    Note:
        The `predicate` attribute for this function is a coroutine.

    Args:
        *checks (Check[ContextT]): Checks built via `check` or any of the higher-level factories
            (`has_role`, `has_any_role`, `has_permission`,
            `has_permissions`).

    Returns:
        `CheckDepenendcy`: A `CheckDependency` that runs each wrapped check in sequence and
        passes on the first success.

    Raises:
        TypeError: A passed check has no `predicate` attribute (i.e. was not
            built via `check`).
        CheckAnyFailure: All checks have failed

    Example:
        Allow either an admin/manager OR the event's owner to transfer it::

            @router.post(
                "/events/{event_id}/transfer",
                dependencies=[
                    check_any(
                        has_any_role(Role.ADMIN, Role.MANAGER),
                        has_permission(Event.own),
                    ),
                ],
            )
            async def transfer_event(...): ...
    """

    unwrapped: list[CheckPredicate[ContextT]] = []
    for wrapped in checks:
        try:
            pred = wrapped.predicate
        except AttributeError:
            msg = f"{wrapped!r} must be wrapped by commands.check decorator"
            raise TypeError(msg) from None
        else:
            unwrapped.append(pred)

    async def predicate(ctx: ContextT) -> bool:
        errors = []
        for func in unwrapped:
            try:
                value = await func(ctx)
            except CheckFailure as e:
                errors.append(e)
            else:
                if value:
                    return True
        # if we're here, all checks failed
        raise CheckAnyFailure(unwrapped, errors)

    return check(predicate)


def has_permissions[ContextT: CheckContext](
    *permissions: ResourcePermission,
) -> CheckDependency[CheckContext]:
    """Check that the caller holds all of the listed permissions.

    The permissions passed in must be `ResourcePermission` instances obtained
    from a `Resource` (e.g. `Project.edit`, `Event.own`). On failure,
    raises `MissingPermissions` carrying the list of missing permissions so
    the response can tell the client exactly what they lack.

    Args:
        *permissions (ResourcePermission): The permissions the caller must hold.

    Returns:
        CheckDependency: A `CheckDependency` that passes only when all listed permissions are
        held by the caller.

    Raises:
        TypeError: No permissions were supplied.
        MissingPermissions: Caller lacks the specified permissions

    Example:
        Require both edit and own on a project before allowing deletion::

            @router.delete(
                "/projects/{project_id}",
                dependencies=[has_permissions(Project.edit, Project.own)],
            )
            async def delete_project(...): ...
    """
    if not permissions:
        msg = "has_permissions must contain more than one arguments"
        raise TypeError(msg)

    async def pred(ctx: ContextT) -> bool:
        missing = [
            perm
            for perm in permissions
            if not await ctx.ory.check_permission(
                namespace=perm.resource.namespace,
                resource=str(
                    uuid.UUID(ctx.request.path_params[perm.resource.path_parameter])
                ),
                relation=perm.relation,
                subject_id=ctx.session.identity.id,
            )
        ]

        if not missing:
            return True

        raise MissingPermissions(missing)

    return check(pred)


def has_role(role: Role, /) -> CheckDependency[CheckContext]:
    """Check that the caller has the role specified.

    The role passed in must be a `Role` enum member. Raises `MissingRole`
    if the caller does not hold the role.

    Args:
        role (Role): The role the caller must hold.

    Returns:
        CheckDependency: A `CheckDependency` that passes when the caller holds the role.

    Raises:
        MissingAnyRole: Caller does not hold the role.

    Example:
        Restrict tag mutations to administrators::

            @router.put(
                "/tags/{tag_id}",
                dependencies=[has_role(Role.ADMIN)],
            )
            async def edit_tag(...): ...
    """

    async def predicate(ctx: CheckContext) -> bool:
        allowed = await ctx.ory.check_permission(
            "Role", role, "member", ctx.session.identity.id
        )

        if not allowed:
            raise MissingRole(role)

        return True

    return check(predicate)


def has_any_role(*roles: Role) -> CheckDependency[CheckContext]:
    """Check that the caller has any of the roles specified.

    If the caller holds at least one of the listed roles, this check passes.
    Similar to `has_role`, the values passed in must be `Role` enum
    members. On total failure, raises `MissingAnyRole`.

    Args:
        *roles (Role): The roles to check for. Caller must hold at least one.

    Returns:
        CheckDependency: A instance of `CheckDependency` that passes if any of the listed roles is held.

    Raises:
        TypeError: No roles were supplied.
        MissingAnyRole: The roles given are not listed.

    Example:
        Allow either admins or SIG leads to create events::

            @router.post(
                "/events/create",
                dependencies=[has_any_role(Role.ADMIN, Role.LEADS)],
            )
            async def create_event(...): ...
    """

    if not roles:
        msg = "has_any_role needs at least one role"
        raise TypeError(msg)

    async def predicate(ctx: CheckContext) -> bool:
        if await _async_any(
            ctx.ory.check_permission("Role", role, "member", ctx.session.identity.id)
            for role in roles
        ):
            return True

        raise MissingAnyRole(list(roles))

    return check(predicate)
