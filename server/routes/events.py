import datetime
import uuid
from dataclasses import asdict
from typing import Annotated, Literal, Optional, Union

import asyncpg
import base62
from argon2 import Parameters
from argon2.low_level import Type
from dateutil import tz
from dateutil.relativedelta import relativedelta
from fastapi import Depends, Query
from pydantic import BaseModel, model_validator
from supertokens_python.recipe.session import SessionContainer
from supertokens_python.recipe.session.framework.fastapi import verify_session
from typing_extensions import Self
from utils.exceptions import ConflictException, ForbiddenException, NotFoundException
from utils.pages import KanaePages, KanaeParams, paginate
from utils.request import RouteRequest
from utils.responses.exceptions import (
    ConflictResponse,
    ErrorResponse,
    ForbiddenResponse,
    NotFoundResponse,
)
from utils.responses.success import DeleteResponse, JoinResponse, SuccessResponse
from utils.roles import has_any_role
from utils.router import KanaeRouter

_TYPE_TO_NAME = {Type.ID: "argon2id", Type.I: "argon2i", Type.D: "argon2d"}
_REQUIRED_KEYS = ("v", "m", "t", "p")
_CONDENSED_KEYS = {
    "version": "v",
    "memory_cost": "m",
    "time_cost": "t",
    "parallelism": "p",
}

router = KanaeRouter(tags=["Events"])


# Basically to take the params set within argon2.PasswordHasher, and compile them into arguments for validation purposes
def compile_params(params: Parameters) -> str:
    def _join_parts(part: tuple[str, str]) -> str:
        return "=".join(part)

    parts = [_TYPE_TO_NAME[params.type]]
    sorted_parts = sorted(
        [
            (_CONDENSED_KEYS[key], str(param))
            for key, param in asdict(params).items()
            if key not in ("type", "salt_len", "hash_len")
        ],
        key=lambda x: _REQUIRED_KEYS.index(x[0]),
    )

    parts.extend(
        [_join_parts(sorted_parts[0]), ",".join(map(_join_parts, sorted_parts[1:]))]
    )
    return f"${'$'.join(parts)}$"


class EventTimezone:
    __slots__ = "pool"

    def __init__(self, *, pool: asyncpg.Pool):
        self.pool = pool

    async def get_raw_timezone(self, id: uuid.UUID) -> str:
        query = "SELECT timezone FROM events WHERE id = $1;"
        row = await self.pool.fetchrow(query, id)
        if not row:
            return "UTC"
        return row["timezone"]

    async def get_tzinfo(self, id: uuid.UUID) -> datetime.tzinfo:
        raw_tz = await self.get_raw_timezone(id)
        return tz.gettz(raw_tz) or datetime.timezone.utc


class Events(BaseModel, frozen=True):
    id: uuid.UUID
    name: str
    description: str
    start_at: datetime.datetime
    end_at: datetime.datetime
    location: str
    type: Literal[
        "general",
        "sig_ai",
        "sig_swe",
        "sig_cyber",
        "sig_data",
        "sig_arch",
        "social",
        "misc",
    ]
    timezone: str
    creator_id: uuid.UUID


@router.get("/events")
async def list_events(
    request: RouteRequest,
    name: Annotated[Optional[str], Query(min_length=3)] = None,
    *,
    params: Annotated[KanaeParams, Depends()],
) -> KanaePages[Events]:
    """Search a list of events"""
    query = """
    SELECT id, name, description, start_at, end_at, location, type, timezone, creator_id
    FROM events
    ORDER BY start_at DESC
    """

    if name:
        query = """
        SELECT id,name, description, start_at, end_at, location, type, timezone, creator_id
        FROM events
        WHERE name % $1
        ORDER BY similarity(name, $1) DESC
        """

    args = (name) if name else ()
    return await paginate(request.app.pool, query, *args, params=params)


@router.get(
    "/events/{id}",
    responses={200: {"model": Events}, 404: {"model": NotFoundResponse}},
)
async def get_event(request: RouteRequest, id: uuid.UUID) -> Events:
    """Retrieve event details via ID"""
    query = """
    SELECT id, name, description, start_at, end_at, location, type, timezone, creator_id
    FROM events
    WHERE id = $1;
    """

    rows = await request.app.pool.fetchrow(query, id)
    if not rows:
        raise NotFoundException
    event_tz = EventTimezone(pool=request.app.pool)
    return Events(**dict(rows), timezone=await event_tz.get_raw_timezone(id))


class ModifiedEvent(BaseModel, frozen=True):
    name: str
    description: str
    location: str


class ModifiedEventWithDatetime(ModifiedEvent, frozen=True):
    start_at: datetime.datetime
    end_at: datetime.datetime
    timezone: str


@router.put(
    "/events/{id}",
    responses={200: {"model": Events}, 404: {"model": NotFoundResponse}},
)
@has_any_role("admin", "leads")
@router.limiter.limit("10/minute")
async def edit_event(
    request: RouteRequest,
    id: uuid.UUID,
    req: Union[ModifiedEvent, ModifiedEventWithDatetime],
    session: Annotated[SessionContainer, Depends(verify_session())],
) -> Events:
    """Updates the specified event"""
    query = """
    UPDATE events
    SET 
        name = $3,
        description = $4,
        location = $5
    WHERE id = $1 AND creator_id = $2
    RETURNING *;
    """

    if isinstance(req, ModifiedEventWithDatetime):
        query = """
        UPDATE events
        SET 
            name = $3,
            description = $4,
            location = $5,
            start_at = $6,
            end_at = $7,
            timezone = $8
        WHERE id = $1 AND creator_id = $2
        RETURNING *;
        """

    update_hash_query = (
        "UPDATE events SET attendance_hash = $3 WHERE id = $1 AND creator_id = $2;"
    )
    async with request.app.pool.acquire() as connection:
        rows = await connection.fetchrow(
            query, id, session.get_user_id(), *req.model_dump().values()
        )
        if not rows:
            raise NotFoundException(
                detail="Resource cannot be updated"
            )  # Not sure if this is correct by RFC 9110 standards

        full_hash = compile_params(request.app.ph._parameters) + rows["attendance_hash"]
        if request.app.ph.check_needs_rehash(full_hash):
            await connection.execute(
                update_hash_query,
                id,
                session.get_user_id(),
                request.app.ph.hash(str(id)),
            )

        return Events(**dict(rows))


@router.delete(
    "/events/{id}",
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundResponse}},
)
@has_any_role("admin", "leads")
@router.limiter.limit("10/minute")
async def delete_event(
    request: RouteRequest,
    id: uuid.UUID,
    session: Annotated[SessionContainer, Depends(verify_session())],
) -> DeleteResponse:
    """Deletes the specified event"""
    query = """
    DELETE FROM events
    WHERE id = $1 AND creator_id = $2;
    """

    status = await request.app.pool.execute(query, id, session.get_user_id())
    if status[-1] == "0":
        raise NotFoundException
    return DeleteResponse()


@router.post(
    "/events/create",
    responses={200: {"model": Events}, 409: {"model": ConflictResponse}},
)
@has_any_role("admin", "leads")
@router.limiter.limit("15/minute")
async def create_events(
    request: RouteRequest,
    req: Events,
    session: Annotated[SessionContainer, Depends(verify_session())],
) -> Events:
    """Creates a new event given the provided data"""
    query = """
    INSERT INTO events (name, description, start_at, end_at, location, type, timezone, creator_id)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    RETURNING *;
    """
    attendance_query = """
    UPDATE events
    SET 
        attendance_hash = $3,
        attendance_code = $4
    WHERE id = $1 AND creator_id = $2;
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()

        try:
            rows = await request.app.pool.fetchrow(
                query, *req.model_dump().values(), session.get_user_id()
            )
            encoded_hash = request.app.ph.hash(str(rows["id"]))

            # note that the salt is stored along with the hash
            await request.app.pool.execute(
                attendance_query,
                rows["id"],
                session.get_user_id(),
                "$".join(encoded_hash.split("$")[-2:]),
                base62.encodebytes(encoded_hash.split("$")[-1].encode("utf-8")),
            )
        except asyncpg.UniqueViolationError:
            await tr.rollback()
            raise ConflictException("Requested project already exists")
        else:
            await tr.commit()
            return Events(**dict(rows))


@router.post(
    "/events/{id}/join",
    responses={
        200: {"model": JoinResponse},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
        409: {"model": ConflictResponse},
    },
)
@router.limiter.limit("5/minute")
async def join_event(
    request: RouteRequest,
    id: uuid.UUID,
    session: Annotated[SessionContainer, Depends(verify_session())],
) -> JoinResponse:
    """Registers and joins an upcoming event"""
    query = """
    SELECT start_at, end_at FROM events WHERE id = $1;
    """

    insert_query = """
    INSERT INTO events_members (event_id, member_id, planned)
    VALUES ($1, $2, TRUE);
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()

        rows = await connection.fetchrow(query, id)
        if not rows:
            raise NotFoundException("Should not happen")

        zone = EventTimezone(pool=request.app.pool)

        now = datetime.datetime.now(await zone.get_tzinfo(id))
        if now > rows["end_at"]:
            raise ForbiddenException(
                "The event has ended. You can't join an finished event."
            )

        await tr.start()

        try:
            await connection.execute(insert_query, id, session.get_user_id())
        except asyncpg.UniqueViolationError:
            await tr.rollback()
            raise ConflictException(
                "Authenticated member has already joined the requested event"
            )
        else:
            await tr.commit()
            return JoinResponse()


class VerifyFailedResponse(ErrorResponse, frozen=True):
    message: str = "Failed to verify, entirely invalid hash"


class VerifyRequest(BaseModel, frozen=True):
    code: str

    @model_validator(mode="before")
    def check_code_length(self) -> Self:
        if len(self.code) > 8:
            raise ValueError("Must be 8 characters or less")
        return self


# Would this have the classic retry behavior of Twitter/X? Need to test
@router.post(
    "/events/{id}/verify",
    responses={
        200: {"model": SuccessResponse},
        403: {"model": VerifyFailedResponse},
        404: {"model": NotFoundResponse},
    },
)
@router.limiter.limit("5/second")
async def verify_attendance(
    request: RouteRequest,
    id: uuid.UUID,
    req: VerifyRequest,
    session: Annotated[SessionContainer, Depends(verify_session())],
):
    """Verify an authenticated user's attendance to the requested event"""
    query = "SELECT start_at, end_at, attendance_hash FROM events WHERE substring(attendance_code for 8) = $1;"
    record = await request.app.pool.fetchrow(query, req.code)
    if not record:
        raise NotFoundException(
            detail="Apparently there is no attendance hash... Hmmmm.... this should never happen"
        )

    full_hash = compile_params(request.app.ph._parameters) + record["attendance_hash"]

    zone = EventTimezone(pool=request.app.pool)

    now = datetime.datetime.now(await zone.get_tzinfo(id))

    # As of now, the buffer times for registering would be:
    # - between the start and end at times
    # - one our before the event
    buffer = record["start_at"] + relativedelta(hours=-1)
    if not (now >= record["start_at"] and now <= record["end_at"]) or (now <= buffer):
        raise NotFoundException(
            "You must verify your hash either during the event or one hour beforehand. Please try again."
        )

    # should raise a error directly, which would need to be handled.
    if request.app.ph.verify(full_hash, str(id)):
        verify_query = """
        INSERT INTO events_members (event_id, member_id, attended)
        VALUES ($1, $2, TRUE)
        ON CONFLICT (event_id, member_id) DO UPDATE
        SET attended = excluded.attended;
        """
        await request.app.pool.execute(verify_query, id, session.get_user_id())

    return SuccessResponse(message="Successfully verified attendance!")
