import datetime
import uuid
from dataclasses import asdict
from typing import Annotated, Literal, Optional, Self

import asyncpg
import base62
from argon2 import Parameters
from argon2.low_level import Type
from dateutil import tz
from dateutil.relativedelta import relativedelta
from fastapi import Depends, Query
from pydantic import BaseModel, model_validator
from utils.auth import use_session
from utils.checks import Event, Role, has_any_role, has_permissions
from utils.errors import ConflictError, ForbiddenError, NotFoundError
from utils.ory import KanaeSession
from utils.pages import KanaePages, KanaeParams, paginate
from utils.request import RouteRequest
from utils.responses import (
    ConflictResponse,
    DeleteResponse,
    ErrorResponse,
    ForbiddenResponse,
    JoinResponse,
    NotFoundResponse,
    SuccessResponse,
)
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
    __slots__ = ("pool",)

    def __init__(self, *, pool: asyncpg.Pool) -> None:
        self.pool = pool

    async def get_raw_timezone(self, event_id: uuid.UUID) -> str:
        query = "SELECT timezone FROM events WHERE id = $1;"
        row = await self.pool.fetchrow(query, event_id)
        if not row:
            return "UTC"
        return row["timezone"]

    async def get_tzinfo(self, event_id: uuid.UUID) -> datetime.tzinfo:
        raw_tz = await self.get_raw_timezone(event_id)
        return tz.gettz(raw_tz) or datetime.UTC


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
        "sig_graph",
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

    args = name or ()
    return await paginate(request.app.pool, query, *args, params=params)  # ty: ignore[invalid-return-type]


@router.get(
    "/events/{event_id}",
    responses={200: {"model": Events}, 404: {"model": NotFoundResponse}},
)
async def get_event(request: RouteRequest, event_id: uuid.UUID) -> Events:
    """Retrieve event details via ID"""
    query = """
    SELECT id, name, description, start_at, end_at, location, type, timezone, creator_id
    FROM events
    WHERE id = $1;
    """

    rows = await request.app.pool.fetchrow(query, event_id)
    if not rows:
        raise NotFoundError
    event_tz = EventTimezone(pool=request.app.pool)
    return Events(**dict(rows), timezone=await event_tz.get_raw_timezone(event_id))


class ModifiedEvent(BaseModel, frozen=True):
    name: str
    description: str
    location: str


class ModifiedEventWithDatetime(ModifiedEvent, frozen=True):
    start_at: datetime.datetime
    end_at: datetime.datetime
    timezone: str


@router.put(
    "/events/{event_id}",
    dependencies=[has_permissions(Event.edit)],
    responses={200: {"model": Events}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("10/minute")
async def edit_event(
    request: RouteRequest,
    event_id: uuid.UUID,
    req: ModifiedEvent | ModifiedEventWithDatetime,
) -> Events:
    """Updates the specified event"""
    query = """
    UPDATE events
    SET
        name = $2,
        description = $3,
        location = $4
    WHERE id = $1
    RETURNING *;
    """

    if isinstance(req, ModifiedEventWithDatetime):
        query = """
        UPDATE events
        SET
            name = $2,
            description = $3,
            location = $4,
            start_at = $5,
            end_at = $6,
            timezone = $7
        WHERE id = $1
        RETURNING *;
        """

    update_hash_query = (
        "UPDATE event_attendance_codes SET attendance_hash = $2 WHERE event_id = $1;"
    )
    fetch_hash_query = (
        "SELECT attendance_hash FROM event_attendance_codes WHERE event_id = $1;"
    )
    async with request.app.pool.acquire() as connection:
        rows = await connection.fetchrow(query, event_id, *req.model_dump().values())
        if not rows:
            raise NotFoundError(
                detail="Resource cannot be updated"
            )  # Not sure if this is correct by RFC 9110 standards

        hash_row = await connection.fetchrow(fetch_hash_query, event_id)
        if hash_row:
            full_hash = (
                compile_params(request.app.ph._parameters) + hash_row["attendance_hash"]
            )
            if request.app.ph.check_needs_rehash(full_hash):
                await connection.execute(
                    update_hash_query,
                    event_id,
                    request.app.ph.hash(str(event_id)),
                )

        return Events(**dict(rows))


@router.delete(
    "/events/{event_id}",
    dependencies=[has_permissions(Event.own)],
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("10/minute")
async def delete_event(
    request: RouteRequest,
    event_id: uuid.UUID,
) -> DeleteResponse:
    """Deletes the specified event"""
    query = """
    DELETE FROM events
    WHERE id = $1;
    """

    status = await request.app.pool.execute(query, event_id)
    if status[-1] == "0":
        raise NotFoundError
    return DeleteResponse()


@router.post(
    "/events/create",
    dependencies=[has_any_role(Role.ADMIN, Role.LEADS)],
    responses={200: {"model": Events}, 409: {"model": ConflictResponse}},
)
@router.limiter.limit("15/minute")
async def create_events(
    request: RouteRequest,
    req: Events,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> Events:
    """Creates a new event given the provided data"""
    query = """
    INSERT INTO events (name, description, start_at, end_at, location, type, timezone, creator_id)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    RETURNING *;
    """
    attendance_query = """
    INSERT INTO event_attendance_codes (event_id, attendance_hash, attendance_code)
    VALUES ($1, $2, $3)
    ON CONFLICT (event_id) DO UPDATE
    SET attendance_hash = EXCLUDED.attendance_hash,
        attendance_code = EXCLUDED.attendance_code;
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()

        try:
            rows = await request.app.pool.fetchrow(
                query,
                *req.model_dump(exclude={"id", "creator_id"}).values(),
                session.identity.id,
            )
            encoded_hash = request.app.ph.hash(str(rows["id"]))

            # note that the salt is stored along with the hash
            await request.app.pool.execute(
                attendance_query,
                rows["id"],
                "$".join(encoded_hash.split("$")[-2:]),
                base62.encodebytes(encoded_hash.split("$")[-1].encode("utf-8")),
            )
        except asyncpg.UniqueViolationError:
            await tr.rollback()
            msg = "Requested project already exists"
            raise ConflictError(msg)
        else:
            await tr.commit()
            return Events(**dict(rows))


@router.post(
    "/events/{event_id}/join",
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
    event_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
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

        rows = await connection.fetchrow(query, event_id)
        if not rows:
            msg = "Should not happen"
            raise NotFoundError(msg)

        zone = EventTimezone(pool=request.app.pool)

        now = datetime.datetime.now(await zone.get_tzinfo(event_id))
        if now > rows["end_at"]:
            msg = "The event has ended. You can't join an finished event."
            raise ForbiddenError(msg)

        await tr.start()

        try:
            await connection.execute(insert_query, event_id, session.identity.id)
        except asyncpg.UniqueViolationError:
            await tr.rollback()
            msg = "Authenticated member has already joined the requested event"
            raise ConflictError(msg)
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
            msg = "Must be 8 characters or less"
            raise ValueError(msg)
        return self


# Would this have the classic retry behavior of Twitter/X? Need to test
@router.post(
    "/events/{event_id}/verify",
    responses={
        200: {"model": SuccessResponse},
        403: {"model": VerifyFailedResponse},
        404: {"model": NotFoundResponse},
    },
)
@router.limiter.limit("5/second")
async def verify_attendance(
    request: RouteRequest,
    event_id: uuid.UUID,
    req: VerifyRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> SuccessResponse:
    """Verify an authenticated user's attendance to the requested event"""
    query = """
    SELECT events.start_at, events.end_at, event_attendance_codes.attendance_hash
    FROM events
    JOIN event_attendance_codes ON events.id = event_attendance_codes.event_id
    WHERE substring(event_attendance_codes.attendance_code for 8) = $1;
    """
    record = await request.app.pool.fetchrow(query, req.code)
    if not record:
        raise NotFoundError(
            detail="Apparently there is no attendance hash... Hmmmm.... this should never happen"
        )

    full_hash = compile_params(request.app.ph._parameters) + record["attendance_hash"]

    zone = EventTimezone(pool=request.app.pool)

    now = datetime.datetime.now(await zone.get_tzinfo(event_id))

    # As of now, the buffer times for registering would be:
    # - between the start and end at times
    # - one our before the event
    buffer = record["start_at"] + relativedelta(hours=-1)
    if not (now >= record["start_at"] and now <= record["end_at"]) or (now <= buffer):
        msg = "You must verify your hash either during the event or one hour beforehand. Please try again."
        raise NotFoundError(msg)

    # should raise a error directly, which would need to be handled.
    if request.app.ph.verify(full_hash, str(event_id)):
        verify_query = """
        INSERT INTO events_members (event_id, member_id, attended)
        VALUES ($1, $2, TRUE)
        ON CONFLICT (event_id, member_id) DO UPDATE
        SET attended = excluded.attended;
        """
        await request.app.pool.execute(verify_query, event_id, session.identity.id)

    return SuccessResponse(message="Successfully verified attendance!")
