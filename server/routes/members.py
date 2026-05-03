import datetime
import secrets
import uuid
from typing import Annotated, Optional

import asyncpg
from blake3 import blake3
from fastapi import Depends, Header, status
from fastapi.responses import Response
from pydantic import BaseModel
from utils.auth import use_session
from utils.exceptions import (
    NotFoundException,
    UnauthorizedException,
)
from utils.ory import KanaeSession
from utils.request import RouteRequest
from utils.responses.exceptions import (
    NotFoundResponse,
    UnauthorizedResponse,
)
from utils.responses.success import SuccessResponse
from utils.router import KanaeRouter

from .events import Events
from .projects import Projects

# Per-hook context labels. If regenerating hook keys, the version suffix must be bumped to change them
_SETTINGS_CONTEXT = b"kratos.settings.v1"
_REGISTRATION_CONTEXT = b"kratos.registration.v1"

# This is not a token lol
_INVALID_WEBHOOK_TOKEN_MESSAGE = "Invalid webhook token detected"  # noqa: S105

router = KanaeRouter(tags=["Members"])


def _verify_webhook_token(token: str, *, master_key: str, context: bytes) -> bool:
    expected_token = blake3(context, key=bytes.fromhex(master_key)).hexdigest()
    return secrets.compare_digest(token, expected_token)


class ClientMember(BaseModel, frozen=True):
    id: uuid.UUID
    name: str
    created_at: datetime.datetime
    projects: list[Projects]
    events: list[Events]


async def get_member_info(
    member_id: str | uuid.UUID, *, pool: asyncpg.Pool
) -> ClientMember:
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
        raise NotFoundException
    return ClientMember(**(dict(rows)))


@router.get(
    "/members/me",
    responses={200: {"model": ClientMember}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("10/minute")
async def get_logged_member(
    request: RouteRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> ClientMember:
    """Obtain details pertaining to the currently authenticated user"""
    return await get_member_info(session.identity.id, pool=request.app.pool)


@router.get(
    "/members/{member_id}",
    responses={200: {"model": ClientMember}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("10/minute")
async def get_member(request: RouteRequest, member_id: uuid.UUID) -> ClientMember:
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
        args.append(since)  # ty: ignore[invalid-argument-type]

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
) -> list[Events]:
    """Obtains events associated with the currently authenticated member.

    Note that using both `planned` and `attended` queries would result in events that have been planned and attended
    (i.e., both queries would be used to search for an AND query)
    """
    constraint = ""

    if planned and attended:
        constraint = (
            "AND events_members.planned = true AND events_members.attended = true"
        )

    if planned:
        constraint = "AND events_members.planned = true"
    elif attended:
        constraint = "AND events_members.attended = true"

    # ruff: noqa: S608
    # This error says "possible SQL injection", but the variables are not passed in to the query directly
    # Instead, they are used to check for the constraint query
    query = f"""
    SELECT events.id, events.name, events.description, events.start_at, events.end_at, events.location, events.type, events.timezone, events.creator_id
    FROM members
        INNER JOIN events_members ON members.id = events_members.member_id {constraint}
        INNER JOIN events ON events_members.event_id = events.id
    WHERE members.id = $1
    GROUP BY events.id;
    """
    rows = await request.app.pool.fetch(query, session.identity.id)
    return [Events(**dict(record)) for record in rows]


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

    return SuccessResponse(message="okie dokie")


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
        raise UnauthorizedException(_INVALID_WEBHOOK_TOKEN_MESSAGE)

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
        raise UnauthorizedException(_INVALID_WEBHOOK_TOKEN_MESSAGE)

    await _upsert_member(request, payload)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
