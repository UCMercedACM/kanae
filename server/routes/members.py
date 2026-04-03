import datetime
import uuid
from typing import Annotated, Optional

import asyncpg
from email_validator import EmailNotValidError, validate_email
from fastapi import Depends
from pydantic import BaseModel
from supertokens_python.asyncio import get_user, list_users_by_account_info
from supertokens_python.recipe.accountlinking.asyncio import is_email_change_allowed
from supertokens_python.recipe.emailpassword.asyncio import (
    update_email_or_password,
    verify_credentials,
)
from supertokens_python.recipe.emailpassword.interfaces import (
    PasswordPolicyViolationError,
    WrongCredentialsError,
)
from supertokens_python.recipe.emailverification.asyncio import (
    is_email_verified,
    send_email_verification_email,
)
from supertokens_python.recipe.passwordless.asyncio import update_user
from supertokens_python.recipe.passwordless.interfaces import (
    UpdateUserEmailAlreadyExistsError,
    UpdateUserOkResult,
)
from supertokens_python.recipe.session import SessionContainer
from supertokens_python.recipe.session.asyncio import revoke_all_sessions_for_user
from supertokens_python.recipe.session.framework.fastapi import verify_session
from supertokens_python.types.base import AccountInfoInput, User
from utils.exceptions import (
    BadRequestException,
    ConflictException,
    HTTPException,
    NotFoundException,
    UnauthorizedException,
)
from utils.request import RouteRequest
from utils.responses.exceptions import (
    BadRequestResponse,
    ConflictResponse,
    NotFoundResponse,
    UnauthorizedResponse,
)
from utils.responses.success import SuccessResponse
from utils.router import KanaeRouter

from .events import Events
from .projects import Projects

router = KanaeRouter(tags=["Members"])


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
    SELECT members.id,
        members.name,
        members.created_at,
        jsonb_agg_strict(projects.*) AS projects,
        jsonb_agg_strict(
            jsonb_build_object(
                'id',
                events.id,
                'name',
                events.name,
                'description',
                events.description,
                'start_at',
                events.start_at,
                'end_at',
                events.end_at,
                'location',
                events.location,
                'type',
                events.type,
                'timezone',
                events.timezone,
                'creator_id',
                events.creator_id
            )
        ) AS events
    FROM members
        INNER JOIN project_members ON members.id = project_members.member_id
        INNER JOIN projects ON project_members.project_id = projects.id
        INNER JOIN events_members ON members.id = events_members.member_id
        INNER JOIN events ON events_members.event_id = events.id
    WHERE members.id = $1
    GROUP BY members.id;
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
    session: Annotated[SessionContainer, Depends(verify_session())],
) -> ClientMember:
    """Obtain details pertaining to the currently authenticated user"""
    return await get_member_info(session.get_user_id(), pool=request.app.pool)


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
    session: Annotated[SessionContainer, Depends(verify_session())],
    since: Optional[datetime.datetime] = None,
) -> list[Projects]:
    """Obtains projects associated with the currently authenticated member, with options to sort"""
    args = [session.get_user_id()]

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
    session: Annotated[SessionContainer, Depends(verify_session())],
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
    rows = await request.app.pool.fetch(query, session.get_user_id())
    return [Events(**dict(record)) for record in rows]


class ModifiedClient(BaseModel, frozen=True):
    name: Optional[str] = None
    email: Optional[str] = None
    old_password: Optional[str] = None
    new_password: Optional[str] = None


async def _update_password(
    req: ModifiedClient,
    session: SessionContainer,
    member_info: User,
) -> SuccessResponse:
    login_method = next(
        (
            method
            for method in member_info.login_methods
            if method.recipe_user_id.get_as_string() == session.get_recipe_user_id()
            and method.recipe_id == "emailpassword"
        ),
        None,
    )

    if not login_method or not login_method.email or not req.old_password:
        raise NotFoundException(detail="No email found or invalid login method used")

    is_valid_password = await verify_credentials(
        "public", login_method.email, req.old_password
    )
    if isinstance(is_valid_password, WrongCredentialsError):
        msg = "Wrong credentials provided"
        raise UnauthorizedException(msg)

    response = await update_email_or_password(
        session.get_recipe_user_id(),
        password=req.new_password,
        tenant_id_for_password_policy=session.get_tenant_id(),
    )
    if isinstance(response, PasswordPolicyViolationError):
        msg = "Password conflicts with current password policy"
        raise ConflictException(msg)

    await revoke_all_sessions_for_user(session.get_user_id())
    await session.revoke_session()

    return SuccessResponse(
        message="Password successfully changed. Log in again to use your new password"
    )


async def _check_email_conflicts(
    session: SessionContainer, normalized_email: str
) -> None:
    member = await get_user(session.get_user_id())

    if member:
        for tenant_id in member.tenant_ids:
            members_with_same_email = await list_users_by_account_info(
                tenant_id, AccountInfoInput(email=normalized_email)
            )
            for curr_member in members_with_same_email:
                if curr_member.id != session.get_user_id():
                    msg = "Requested email conflicts with other members"
                    raise ConflictException(msg)


async def _update_email(
    request: RouteRequest,
    req: ModifiedClient,
    session: SessionContainer,
) -> SuccessResponse:
    if not req.email:
        msg = "Email is required"
        raise BadRequestException(msg)

    is_valid_email = validate_email(req.email, check_deliverability=True)
    if isinstance(is_valid_email, EmailNotValidError):
        msg = "Email is not valid"
        raise BadRequestException(msg)

    normalized_email = is_valid_email.normalized
    is_verified = is_email_verified(session.get_recipe_user_id(), normalized_email)

    if not is_verified:
        if not is_email_change_allowed(
            session.get_recipe_user_id(), normalized_email, False
        ):
            msg = "Email change not allowed"
            raise BadRequestException(msg)

        await _check_email_conflicts(session, normalized_email)

        await send_email_verification_email(
            session.get_tenant_id(),
            session.get_user_id(),
            session.get_recipe_user_id(),
            normalized_email,
        )
        return SuccessResponse(
            message="Sent email verification message. Please check your email and spam folder"
        )

    response = await update_user(session.get_recipe_user_id(), email=normalized_email)

    if isinstance(response, UpdateUserOkResult):
        query = "UPDATE members SET email = $2 WHERE id = $1;"
        await request.app.pool.execute(query, session.get_user_id(), normalized_email)
        return SuccessResponse(message="Successfully changed email")

    if isinstance(response, UpdateUserEmailAlreadyExistsError):
        msg = "Email already exists, try another one"
        raise ConflictException(msg)

    raise HTTPException(status_code=500, detail="How...")


@router.put(
    "/members/me/update",
    responses={
        200: {"model": SuccessResponse},
        400: {"model": BadRequestResponse},
        401: {"model": UnauthorizedResponse},
        404: {"model": NotFoundResponse},
        409: {"model": ConflictResponse},
    },
)
@router.limiter.limit("2 per 15 minutes")
async def update_logged_member(
    request: RouteRequest,
    req: ModifiedClient,
    session: Annotated[SessionContainer, Depends(verify_session())],
) -> SuccessResponse:
    """Updates information for the currently authenticated member"""
    member_info = await get_user(session.get_user_id())

    if not member_info:
        raise NotFoundException

    if req.old_password and req.new_password:
        return await _update_password(req, session, member_info)

    if req.name:
        query = "UPDATE members SET name = $2 WHERE id = $1"
        await request.app.pool.execute(query, session.get_user_id(), req.name)
        return SuccessResponse(message="Name successfully changed")

    if req.email:
        return await _update_email(request, req, session)

    raise HTTPException(status_code=500, detail="How...")
