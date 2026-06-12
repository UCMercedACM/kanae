import datetime
import uuid
from typing import Annotated, Optional

from fastapi import Depends
from pydantic import BaseModel, Field

from utils.auth import use_session
from utils.checks import Role, has_2fa, has_role
from utils.ory import KanaeSession
from utils.request import RouteRequest
from utils.responses import (
    ForbiddenResponse,
    SuccessResponse,
)
from utils.router import KanaeRouter

router = KanaeRouter(tags=["Sudo"])

_NO_NULL_REGEX = r"^[^\x00]+$"


class Sudo(BaseModel, frozen=True):
    active: bool
    expires_at: Optional[datetime.datetime] = None


class ActiveSudo(BaseModel, frozen=True):
    member_id: uuid.UUID
    granted_at: datetime.datetime
    expires_at: datetime.datetime
    reason: str


@router.get(
    "/sudo",
    dependencies=[has_role(Role.ADMIN)],
    responses={200: {"model": Sudo}},
    include_in_schema=False,
)
@router.limiter.limit("30/minute")
async def get_sudo(
    request: RouteRequest, session: Annotated[KanaeSession, Depends(use_session)]
) -> Sudo:
    """Obtain current sudo session"""
    expires_at = await request.app.sudo.get_expiry(session.identity.id)
    return Sudo(active=expires_at is not None, expires_at=expires_at)


@router.get("/sudo/active", dependencies=[has_role(Role.ROOT)], include_in_schema=False)
async def get_active_sudo_grants(
    request: RouteRequest, session: Annotated[KanaeSession, Depends(use_session)]
) -> list[ActiveSudo]:
    """Get all active sudo grants"""
    query = """
    SELECT member_id, granted_at, expires_at, reason
    FROM sudo_grants
    WHERE expires_at > now()
    ORDER BY granted_at DESC;
    """

    rows = await request.app.pool.fetch(query)
    return [ActiveSudo(**dict(row)) for row in rows]


@router.get(
    "/sudo/audit",
    dependencies=[has_role(Role.ROOT)],
    include_in_schema=False,
)
async def get_sudo_audits(
    request: RouteRequest, session: Annotated[KanaeSession, Depends(use_session)]
) -> list[ActiveSudo]:
    """Obtains most recent sudo requests"""
    query = """
    SELECT member_id, granted_at, expires_at, reason
    FROM sudo_audit
    ORDER BY granted_at DESC;
    """
    rows = await request.app.pool.fetch(query)
    return [ActiveSudo(**dict(row)) for row in rows]


class SudoRequest(BaseModel, frozen=True):
    reason: Annotated[str, Field(min_length=1, max_length=200, pattern=_NO_NULL_REGEX)]


@router.post(
    "/sudo/elevate",
    dependencies=[has_role(Role.ADMIN), has_2fa()],
    responses={200: {"model": Sudo}, 403: {"model": ForbiddenResponse}},
    include_in_schema=False,
)
@router.limiter.limit("5/minute")
async def elevate_sudo(
    request: RouteRequest,
    req: SudoRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> Sudo:
    """Elevate to sudo-level access. Grants 10 minutes of sudo-level access"""
    grant_expires_at = await request.app.sudo.grant(
        session.identity.id, reason=req.reason
    )
    return Sudo(active=True, expires_at=grant_expires_at)


@router.delete(
    "/sudo/revoke",
    dependencies=[has_role(Role.ADMIN)],
    responses={200: {"model": SuccessResponse}},
    include_in_schema=False,
)
@router.limiter.limit("10/minute")
async def revoke_sudo(
    request: RouteRequest, session: Annotated[KanaeSession, Depends(use_session)]
) -> SuccessResponse:
    """Revoke sudo access early"""
    await request.app.sudo.revoke(session.identity.id)
    return SuccessResponse(message="Sudo access revoked")
