import datetime
import secrets
import uuid
from enum import StrEnum
from typing import Annotated, Literal, Optional

import asyncpg
from blake3 import blake3
from fastapi import Depends, Header, Query, status
from fastapi.responses import Response
from pydantic import BaseModel

from utils.auth import use_session
from utils.checks import Role, check_any, has_role, has_sudo
from utils.errors import (
    BadRequestError,
    ConflictError,
    ForbiddenError,
    NotFoundError,
    UnauthorizedError,
)
from utils.ory import KanaeSession, OryClient
from utils.pages import KanaePages, KanaeParams, paginate
from utils.request import RouteRequest
from utils.responses import (
    ConflictResponse,
    DeleteResponse,
    NotFoundResponse,
    SuccessResponse,
    UnauthorizedResponse,
)
from utils.router import KanaeRouter

from .events import Events, FullEvents
from .projects import Projects

# Per-hook context labels. If regenerating hook keys, the version suffix must be bumped to change them
_SETTINGS_CONTEXT = b"kratos.settings.v1"
_REGISTRATION_CONTEXT = b"kratos.registration.v1"

# This is not a token lol
_INVALID_WEBHOOK_TOKEN_MESSAGE = "Invalid webhook token detected"  # noqa: S105

_NO_NULL_REGEX = r"^[^\x00]+$"

router = KanaeRouter(tags=["Members"])


def _verify_webhook_token(token: str, *, master_key: str, context: bytes) -> bool:
    expected_token = blake3(context, key=bytes.fromhex(master_key)).hexdigest()
    return secrets.compare_digest(token, expected_token)


class Member(BaseModel, frozen=True):
    id: uuid.UUID
    name: str
    created_at: datetime.datetime
    projects: list[Projects]
    events: list[Events]


async def get_member_info(member_id: str | uuid.UUID, *, pool: asyncpg.Pool) -> Member:
    query = """
    SELECT
        members.id,
        members.name,
        members.created_at,
        (
            SELECT COALESCE(jsonb_agg(projects.*), '[]'::jsonb)
            FROM project_members
                INNER JOIN projects ON project_members.project_id = projects.id
            WHERE project_members.member_id = members.id
        ) AS projects,
        (
            SELECT COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'id', events.id,
                        'name', events.name,
                        'description', events.description,
                        'start_at', events.start_at,
                        'end_at', events.end_at,
                        'location', events.location,
                        'type', events.type,
                        'timezone', events.timezone,
                        'creator_id', events.creator_id
                    )
                ),
                '[]'::jsonb
            )
            FROM events_members
                INNER JOIN events ON events_members.event_id = events.id
            WHERE events_members.member_id = members.id
        ) AS events
    FROM members
    WHERE members.id = $1;
    """
    rows = await pool.fetchrow(query, member_id)
    if not rows:
        raise NotFoundError

    return Member(**(dict(rows)))


async def purge_member(member_id: uuid.UUID, *, ory: OryClient) -> None:
    # Ory Kratos and Keto won't take the raw UUID type but only a string
    normalized_member_id = str(member_id)

    await ory.revoke_all_sessions(normalized_member_id)
    await ory.purge(normalized_member_id)
    await ory.delete_identity(normalized_member_id)


class SimpleMember(BaseModel, frozen=True):
    id: uuid.UUID
    name: str
    display_name: Optional[str] = None
    email: str
    created_at: datetime.datetime


class ClientSession(BaseModel, frozen=True):
    aal: Literal["aal1", "aal2"]
    active: bool
    authenticated_at: datetime.datetime
    issued_at: datetime.datetime
    expires_at: datetime.datetime


class ClientMember(BaseModel, frozen=True):
    id: uuid.UUID
    name: str
    email: str
    display_name: Optional[str] = None
    created_at: datetime.datetime
    projects: list[Projects]
    events: list[Events]
    roles: list[Role]
    session: ClientSession


@router.get("/members", dependencies=[has_role(Role.ADMIN)])
async def list_members(
    request: RouteRequest,
    query: Annotated[Optional[str], Query(min_length=3, pattern=_NO_NULL_REGEX)] = None,
    *,
    params: Annotated[KanaeParams, Depends()],
) -> KanaePages[SimpleMember]:
    """Search the member directory by name or email. Restricted to admins."""
    args: list[str] = []
    member_query = """
    SELECT id, name, display_name, email, created_at
    FROM members
    ORDER BY created_at DESC
    """

    if query:
        member_query = """
        SELECT id, name, display_name, email, created_at
        FROM members
        WHERE name % $1 OR email ILIKE '%' || $1 || '%'
        ORDER BY similarity(name, $1) DESC NULLS LAST
        """
        args.append(query)

    return await paginate(request.app.pool, member_query, *args, params=params)  # ty: ignore[invalid-return-type]


@router.get(
    "/members/me",
    responses={200: {"model": ClientMember}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("10/minute")
async def get_logged_member(
    request: RouteRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> ClientMember:
    """Obtain details pertaining to the currently authenticated user."""
    member = await get_member_info(session.identity.id, pool=request.app.pool)

    return ClientMember(
        **member.model_dump(),
        email=session.identity.email,
        display_name=session.identity.traits.get("display_name"),
        roles=[
            Role(role) async for role in request.app.ory.list_roles(session.identity.id)
        ],
        session=ClientSession(
            aal=session.authenticator_assurance_level,
            active=session.active,
            authenticated_at=session.authenticated_at,
            issued_at=session.issued_at,
            expires_at=session.expires_at,
        ),
    )


@router.get(
    "/members/{member_id}",
    responses={200: {"model": Member}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("10/minute")
async def get_member(request: RouteRequest, member_id: uuid.UUID) -> Member:
    """Obtain details pertaining to the specified user"""
    return await get_member_info(member_id, pool=request.app.pool)


@router.get("/members/me/projects", responses={200: {"model": Projects}})
@router.limiter.limit("10/minute")
async def get_logged_projects(
    request: RouteRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
    since: Optional[datetime.datetime] = None,
) -> list[Projects]:
    """Obtains projects associated with the currently authenticated member, with options to sort"""
    args = [session.identity.id]

    query = """
    SELECT projects.*
    FROM members
        INNER JOIN project_members ON members.id = project_members.member_id
        INNER JOIN projects ON project_members.project_id = projects.id
    WHERE members.id = $1
    GROUP BY projects.id;
    """

    if since:
        query = """
        SELECT projects.*
        FROM members
            INNER JOIN project_members ON members.id = project_members.member_id
            AND project_members.joined_at >= $2
            INNER JOIN projects ON project_members.project_id = projects.id
        WHERE members.id = $1
        GROUP BY projects.id;
        """
        args.append(since)

    rows = await request.app.pool.fetch(query, *args)
    return [Projects(**dict(record)) for record in rows]


@router.get("/members/me/events")
@router.limiter.limit("10/minute")
async def get_logged_events(
    request: RouteRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
    *,
    planned: Optional[bool] = None,
    attended: Optional[bool] = None,
    upcoming: Optional[bool] = None,
    past: Optional[bool] = None,
) -> list[FullEvents]:
    """Obtains events associated with the currently authenticated member.

    `planned`/`attended` filter on RSVP/attendance flags (AND-combined).
    `upcoming`/`past` filter on time (`start_at`/`end_at` vs now) and are
    mutually exclusive.
    """
    if upcoming and past:
        msg = "Cannot specify both upcoming and past."
        raise BadRequestError(msg)

    constraint = ""

    if planned and attended:
        constraint = (
            "AND events_members.planned = true AND events_members.attended = true"
        )

    if planned:
        constraint = "AND events_members.planned = true"
    elif attended:
        constraint = "AND events_members.attended = true"

    args: list = [session.identity.id, request.app.storage.base_thumbnail_url]
    time_constraint = ""
    if upcoming:
        time_constraint = "AND events.start_at > $3"
        args.append(datetime.datetime.now(datetime.UTC))
    elif past:
        time_constraint = "AND events.end_at < $3"
        args.append(datetime.datetime.now(datetime.UTC))

    # ruff: noqa: S608
    # This error says "possible SQL injection", but the variables are not passed in to the query directly
    # Instead, they are used to check for the constraint query
    query = f"""
    SELECT
        events.id, events.name, events.description, events.start_at, events.end_at, events.location, events.type, events.timezone,
        (
            SELECT array_agg(tags.title ORDER BY tags.title)
            FROM event_tags
            JOIN tags ON tags.id = event_tags.tag_id
            WHERE event_tags.event_id = events.id
        ) AS tags,
        CASE WHEN events.thumbnail_hash IS NOT NULL THEN
            jsonb_build_object(
                'hash', events.thumbnail_hash,
                'url', $2 || '/thumbnails/' || events.thumbnail_hash || '.webp'
            )
        END AS thumbnail,
        events.creator_id
    FROM members
        INNER JOIN events_members ON members.id = events_members.member_id {constraint}
        INNER JOIN events ON events_members.event_id = events.id
    WHERE members.id = $1 {time_constraint}
    GROUP BY events.id;
    """
    rows = await request.app.pool.fetch(query, *args)
    return [FullEvents(**dict(record)) for record in rows]


@router.post("/members/logout", responses={200: {"model": SuccessResponse}})
@router.limiter.limit("3/minute")
async def logout_member(
    request: RouteRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> SuccessResponse:
    """Logs the user of the current session out

    Note that cookies for the particular session are immedidiately revoked if present
    """
    cookie = request.cookies.get("ory_kratos_session")
    await request.app.ory.revoke_session(str(session.id))

    if cookie:
        await request.app.ory.whoami.cache_invalidate(cookie)

    return SuccessResponse(message="ok")


class MemberRoles(BaseModel, frozen=True):
    roles: list[Role]


@router.get(
    "/members/{member_id}/roles",
    responses={200: {"model": MemberRoles}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("10/minute")
async def get_member_roles(
    request: RouteRequest,
    member_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> MemberRoles:
    """List a member's global roles."""
    requester_id = session.identity.id
    if str(member_id) != requester_id and not await request.app.ory.check_permission(
        "Role", Role.ADMIN, "member", requester_id
    ):
        msg = "Only an admin may read another member's roles"
        raise ForbiddenError(msg)

    query = "SELECT 1 FROM members WHERE id = $1;"
    if not await request.app.pool.fetchval(query, member_id):
        raise NotFoundError

    roles = [Role(role) async for role in request.app.ory.list_roles(str(member_id))]
    return MemberRoles(roles=roles)


class AssignableRole(StrEnum):
    ADMIN = "admin"
    MANAGER = "manager"
    LEADS = "leads"


class ModifyRoleAction(StrEnum):
    GRANT = "grant"
    REVOKE = "revoke"


class ModifyRoleRequest(BaseModel, frozen=True):
    role: AssignableRole
    action: ModifyRoleAction


@router.put(
    "/members/{member_id}/role",
    dependencies=[check_any(has_role(Role.ROOT), has_sudo())],
    responses={
        200: {"model": SuccessResponse},
        404: {"model": NotFoundResponse},
        409: {"model": ConflictResponse},
    },
)
@router.limiter.limit("5/minute")
async def modify_member_role(
    request: RouteRequest,
    member_id: uuid.UUID,
    req: ModifyRoleRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> SuccessResponse:
    """Modify the role of a given member"""
    if str(member_id) == session.identity.id:
        msg = "Literally refusing to modify your own roles... You can't"
        raise ConflictError(msg)

    query = "SELECT 1 FROM members WHERE id = $1;"
    if not await request.app.pool.fetchval(query, member_id):
        raise NotFoundError

    subject_id = str(member_id)
    if req.action == ModifyRoleAction.GRANT:
        await request.app.ory.grant("Role", req.role, "member", subject_id=subject_id)
    else:
        await request.app.ory.revoke("Role", req.role, "member", subject_id=subject_id)

    return SuccessResponse(message="ok")


@router.delete(
    "/members/me",
    responses={200: {"model": DeleteResponse}},
)
@router.limiter.limit("1/minute")
async def delete_logged_account(
    request: RouteRequest, session: Annotated[KanaeSession, Depends(use_session)]
) -> DeleteResponse:
    """Permanently delete the member associated the currently logged session"""
    member_id = uuid.UUID(session.identity.id)

    query = "DELETE FROM members WHERE id = $1;"
    await purge_member(member_id, ory=request.app.ory)
    await request.app.pool.execute(query, member_id)

    return DeleteResponse(message="okie dokie")


@router.delete(
    "/members/{member_id}",
    dependencies=[check_any(has_role(Role.ROOT), has_sudo())],
    responses={
        200: {"model": DeleteResponse},
        404: {"model": NotFoundResponse},
        409: {"model": ConflictResponse},
    },
)
@router.limiter.limit("1/minute")
async def delete_member(
    request: RouteRequest,
    member_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> DeleteResponse:
    """Permanently deletes an given member"""
    if str(member_id) == session.identity.id:
        msg = "Use DELETE /members/me to delete your own account"
        raise ConflictError(msg)

    query = "DELETE FROM members WHERE id = $1 RETURNING id;"

    await purge_member(member_id, ory=request.app.ory)
    response = await request.app.pool.fetchval(query, member_id)
    if not response:
        raise NotFoundError

    return DeleteResponse(message="okie dokie")


class _IdentityTraits(BaseModel, frozen=True, extra="forbid"):
    email: str
    name: str
    display_name: Optional[str] = None


class _Identity(BaseModel, frozen=True, extra="forbid"):
    id: uuid.UUID
    schema_id: str
    traits: _IdentityTraits


class KratosHookPayload(BaseModel, frozen=True, extra="forbid"):
    """Payload Kratos sends after a settings or registration flow completes.

    Shape is fixed by `payload.jsonnet` in docker/ory/kratos/hooks/.
    """

    flow_id: uuid.UUID
    identity: _Identity


async def _upsert_member(request: RouteRequest, payload: KratosHookPayload) -> None:
    query = """
    INSERT INTO members (id, name, display_name, email)
    VALUES ($1, $2, $3, $4)
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        display_name = EXCLUDED.display_name,
        email = EXCLUDED.email;
    """
    identity_traits = payload.identity.traits
    await request.app.pool.execute(
        query,
        payload.identity.id,
        identity_traits.name,
        identity_traits.display_name,
        identity_traits.email,
    )


@router.post(
    "/member/webhooks/settings",
    responses={401: {"model": UnauthorizedResponse}},
    include_in_schema=False,
)
async def member_settings_hook(
    request: RouteRequest,
    payload: KratosHookPayload,
    x_webhook_token: Annotated[str, Header(strict=True)],
) -> Response:
    """Internal webhook that syncs members after a Kratos self-service settings flow"""
    master_key = request.app.config.ory.kratos_webhook_master_key
    if not _verify_webhook_token(
        token=x_webhook_token, master_key=master_key, context=_SETTINGS_CONTEXT
    ):
        raise UnauthorizedError(_INVALID_WEBHOOK_TOKEN_MESSAGE)

    await _upsert_member(request, payload)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/member/webhooks/registration",
    responses={401: {"model": UnauthorizedResponse}},
    include_in_schema=False,
)
async def member_registration_hook(
    request: RouteRequest,
    payload: KratosHookPayload,
    x_webhook_token: Annotated[str, Header(strict=True)],
) -> Response:
    """Internal webhook that registers members after a new identity is created"""
    master_key = request.app.config.ory.kratos_webhook_master_key
    if not _verify_webhook_token(
        token=x_webhook_token, master_key=master_key, context=_REGISTRATION_CONTEXT
    ):
        raise UnauthorizedError(_INVALID_WEBHOOK_TOKEN_MESSAGE)

    await _upsert_member(request, payload)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
