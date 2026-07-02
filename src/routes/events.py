import datetime
import uuid
from typing import Annotated, Literal, Optional, Self

import asyncpg
import base62
from dateutil import tz
from dateutil.relativedelta import relativedelta
from fastapi import Depends, HTTPException, Query
from pydantic import BaseModel, Field, model_validator

from core import store_thumbnail
from utils.auth import use_session
from utils.checks import Event, Role, has_any_role, has_permissions
from utils.errors import (
    BadGatewayError,
    ConflictError,
    ForbiddenError,
    NotFoundError,
    ServiceUnavailableError,
)
from utils.ory import KanaeSession
from utils.pages import KanaePages, KanaeParams, paginate
from utils.request import RouteRequest
from utils.responses import (
    BadRequestResponse,
    ConflictResponse,
    DeleteResponse,
    ErrorResponse,
    ForbiddenResponse,
    HTTPExceptionResponse,
    JoinResponse,
    NotFoundResponse,
    SuccessResponse,
)
from utils.router import KanaeRouter

_HASH_REGEX = r"^[0-9a-f]{64}$"
_NO_NULL_REGEX = r"^[^\x00]+$"

router = KanaeRouter(tags=["Events"])


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


class EventThumbnail(BaseModel, frozen=True):
    hash: Annotated[str, Field(pattern=_HASH_REGEX)]
    url: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


class Events(BaseModel, frozen=True):
    id: uuid.UUID
    name: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    description: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    start_at: datetime.datetime
    end_at: datetime.datetime
    location: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
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
    timezone: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    creator_id: Optional[uuid.UUID] = None


class FullEvents(BaseModel, frozen=True):
    id: uuid.UUID
    name: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    description: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    start_at: datetime.datetime
    end_at: datetime.datetime
    location: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
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
    timezone: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    thumbnail: Optional[EventThumbnail] = None
    tags: Optional[list[Annotated[str, Field(pattern=_NO_NULL_REGEX)]]] = None
    creator_id: Optional[uuid.UUID] = None


@router.get("/events")
async def list_events(
    request: RouteRequest,
    name: Annotated[Optional[str], Query(min_length=3, pattern=_NO_NULL_REGEX)] = None,
    before: Optional[datetime.datetime] = None,
    after: Optional[datetime.datetime] = None,
    *,
    params: Annotated[KanaeParams, Depends()],
) -> KanaePages[FullEvents]:
    """Search a list of events"""
    args: list = [request.app.storage.base_thumbnail_url, before, after]

    query = """
    SELECT
        id, name, description, start_at, end_at, location, type, timezone,
        CASE WHEN thumbnail_hash IS NOT NULL THEN
            jsonb_build_object(
                'hash', thumbnail_hash,
                'url', $1 || '/thumbnails/' || thumbnail_hash || '.webp'
            )
        END AS thumbnail,
        (
            SELECT array_agg(tags.title ORDER BY tags.title)
            FROM event_tags
            JOIN tags ON tags.id = event_tags.tag_id
            WHERE event_tags.event_id = events.id
        ) AS tags,
        creator_id
    FROM events
    WHERE (start_at <= $2 OR $2 IS NULL)
      AND (start_at >= $3 OR $3 IS NULL)
    ORDER BY start_at DESC
    """

    if name:
        query = """
        SELECT
            id, name, description, start_at, end_at, location, type, timezone,
            CASE WHEN thumbnail_hash IS NOT NULL THEN
                jsonb_build_object(
                    'hash', thumbnail_hash,
                    'url', $1 || '/thumbnails/' || thumbnail_hash || '.webp'
                )
            END AS thumbnail,
            (
                SELECT array_agg(tags.title ORDER BY tags.title)
                FROM event_tags
                JOIN tags ON tags.id = event_tags.tag_id
                WHERE event_tags.event_id = events.id
            ) AS tags,
            creator_id
        FROM events
        WHERE (start_at <= $2 OR $2 IS NULL)
          AND (start_at >= $3 OR $3 IS NULL)
          AND name % $4
        ORDER BY similarity(name, $4) DESC
        """
        args.append(name)

    return await paginate(request.app.pool, query, *args, params=params)  # ty: ignore[invalid-return-type]


@router.get(
    "/events/{event_id}",
    responses={200: {"model": FullEvents}, 404: {"model": NotFoundResponse}},
)
async def get_event(request: RouteRequest, event_id: uuid.UUID) -> FullEvents:
    """Retrieve event details via ID"""
    query = """
    SELECT
        id, name, description, start_at, end_at, location, type,
        CASE WHEN thumbnail_hash IS NOT NULL THEN
            jsonb_build_object(
                'hash', thumbnail_hash,
                'url', $2 || '/thumbnails/' || thumbnail_hash || '.webp'
            )
        END AS thumbnail,
        (
            SELECT array_agg(tags.title ORDER BY tags.title)
            FROM event_tags
            JOIN tags ON tags.id = event_tags.tag_id
            WHERE event_tags.event_id = events.id
        ) AS tags,
        creator_id
    FROM events
    WHERE id = $1;
    """

    rows = await request.app.pool.fetchrow(
        query, event_id, request.app.storage.base_thumbnail_url
    )
    if not rows:
        raise NotFoundError
    event_tz = EventTimezone(pool=request.app.pool)
    return FullEvents(**dict(rows), timezone=await event_tz.get_raw_timezone(event_id))


class ModifiedEvent(BaseModel, frozen=True):
    name: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    description: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    location: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


class ModifiedEventWithDatetime(ModifiedEvent, frozen=True):
    start_at: datetime.datetime
    end_at: datetime.datetime
    timezone: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


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
        if hash_row and request.app.ph.check_needs_rehash(hash_row["attendance_hash"]):
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
    WHERE id = $1
    RETURNING thumbnail_hash
    """

    status = await request.app.pool.fetchrow(query, event_id)
    if status is None:
        raise NotFoundError

    if status["thumbnail_hash"]:
        await request.app.storage.delete_thumbnail(status["thumbnail_hash"])

    return DeleteResponse()


@router.post(
    "/events/create",
    dependencies=[has_any_role(Role.ADMIN, Role.LEADS)],
    responses={200: {"model": Events}},
)
@router.limiter.limit("20/minute")
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
            rows = await connection.fetchrow(
                query,
                *req.model_dump(exclude={"id", "creator_id"}).values(),
                session.identity.id,
            )
            encoded_hash = request.app.ph.hash(str(rows["id"]))

            # store the full encoded hash (the "password" is the event UUID, so
            # it is not secret-sensitive); attendance_code is the base62 of the
            # trailing hash segment and doubles as the 8-char lookup key
            await connection.execute(
                attendance_query,
                rows["id"],
                encoded_hash,
                base62.encodebytes(encoded_hash.split("$")[-1].encode("utf-8")),
            )

            event_id = str(rows["id"])
            await request.app.ory.grant(
                "Event", event_id, "owners", subject_id=session.identity.id
            )
            await request.app.ory.grant(
                "Event",
                event_id,
                "editors",
                subject_set={
                    "namespace": "Role",
                    "object": "leads",
                    "relation": "member",
                },
            )
        except asyncpg.ForeignKeyViolationError:
            await tr.rollback()
            msg = "Creator member does not exist"
            raise NotFoundError(msg)
        except (BadGatewayError, ServiceUnavailableError):
            await tr.rollback()
            msg = "Failed to record event ownership in the authorization service"
            raise BadGatewayError(msg)
        else:
            await tr.commit()
            return Events(**dict(rows))


class SetThumbnailRequest(BaseModel, frozen=True):
    hash: Annotated[str, Field(pattern=_HASH_REGEX)]
    content_type: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


@router.post(
    "/events/{event_id}/thumbnail",
    dependencies=[has_permissions(Event.edit)],
    responses={
        200: {"model": SuccessResponse},
        400: {"model": BadRequestResponse},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
    },
)
@router.limiter.limit("3/minute")
async def set_event_thumbnail(
    request: RouteRequest,
    event_id: uuid.UUID,
    req: SetThumbnailRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> SuccessResponse:
    """Sets the thumbnail used for a given event"""
    processed_image = await store_thumbnail(
        request, media_hash=req.hash, content_type=req.content_type
    )

    # There is a slight but rare race condition if two simultaneous requests can read
    # the pre-updated thumbnail_hash. Issue a "FOR UPDATE" row lock to prevent this race.
    # Without it, two simultaneous requests can each read the pre-update `thumbnail_hash`
    # against their own snapshot, then one's UPDATE commits and the other's cleanup branch
    # deletes a stale hash — leaving the first writer's WebP object orphaned in the public bucket.
    #
    # Unlike projects, events have no media-association table, so there is no
    # `project_media`-style EXISTS guard: a missing row simply means the event does not exist.
    query = """
        WITH locked AS (
            SELECT thumbnail_hash FROM events
            WHERE id = $2
            FOR UPDATE
        ), old AS (
            SELECT thumbnail_hash FROM locked
            WHERE thumbnail_hash IS NOT NULL AND thumbnail_hash != $1
        )
        UPDATE events
        SET thumbnail_hash = $1
        WHERE id = $2
        RETURNING id, (SELECT thumbnail_hash FROM old) AS old_hash;
    """
    response = await request.app.pool.fetchrow(query, processed_image.hash, event_id)

    if response is None:
        await request.app.storage.delete_thumbnail(processed_image.hash)
        msg = "Event not found"
        raise NotFoundError(msg)

    if response["old_hash"]:
        await request.app.storage.delete_thumbnail(response["old_hash"])

    return SuccessResponse(message="ok")


@router.delete(
    "/events/{event_id}/thumbnail",
    dependencies=[has_permissions(Event.edit)],
    responses={
        200: {"model": DeleteResponse},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
    },
)
@router.limiter.limit("5/minute")
async def remove_event_thumbnail(
    request: RouteRequest,
    event_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> DeleteResponse:
    """Removes the associated thumbnail of a given event"""
    query = """
    WITH old_thumbnail AS (
        SELECT thumbnail_hash
        FROM events
        WHERE id = $1
    )
    UPDATE events
    SET thumbnail_hash = NULL
    WHERE id = $1
    RETURNING id, (SELECT thumbnail_hash FROM old_thumbnail) AS old_hash
    """

    response = await request.app.pool.fetchrow(query, event_id)

    if not response:
        raise NotFoundError

    if response["old_hash"]:
        await request.app.storage.delete_thumbnail(response["old_hash"])

    return DeleteResponse()


class EventTagsResponse(BaseModel, frozen=True):
    tags: list[str]


class ModifyEventTags(BaseModel, frozen=True):
    tags: list[Annotated[str, Field(pattern=_NO_NULL_REGEX)]]


@router.put(
    "/events/{event_id}/tags",
    dependencies=[has_permissions(Event.edit)],
    responses={
        200: {"model": EventTagsResponse},
        404: {"model": NotFoundResponse},
        422: {"model": HTTPExceptionResponse},
    },
)
@router.limiter.limit("5/minute")
async def edit_event_tags(
    request: RouteRequest,
    event_id: uuid.UUID,
    req: ModifyEventTags,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> EventTagsResponse:
    """Replaces an event's entire tag set with the supplied one. Also allows for partial edits"""
    query = """
    WITH check_event AS (
        SELECT 1 FROM events
        WHERE id = $1 FOR UPDATE
    ), delete_event_tags AS (
        DELETE FROM event_tags
        WHERE event_id = $1
    )
    SELECT EXISTS (SELECT 1 FROM check_event) AS exists;
    """
    response_query = """
    SELECT tags.title
    FROM event_tags
    JOIN tags ON tags.id = event_tags.tag_id
    WHERE event_tags.event_id = $1
    ORDER BY tags.title;
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()
        try:
            exists = await connection.fetchval(query, event_id)
            if not exists:
                await tr.rollback()
                raise NotFoundError

            if req.tags:
                subquery = """
                INSERT INTO event_tags (event_id, tag_id)
                VALUES ($1, (SELECT id FROM tags WHERE title = $2))
                ON CONFLICT DO NOTHING;
                """
                await connection.executemany(
                    subquery, [(event_id, tag.lower()) for tag in req.tags]
                )

            response_tags = await connection.fetch(
                response_query,
                event_id,
            )
        except asyncpg.NotNullViolationError:
            await tr.rollback()
            raise HTTPException(
                detail="The tag(s) specified is invalid. Please check the current tags available.",
                status_code=422,
            )
        else:
            await tr.commit()

        return EventTagsResponse(tags=[row["title"] for row in response_tags])


@router.delete(
    "/events/{event_id}/tags",
    dependencies=[has_permissions(Event.edit)],
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("5/minute")
async def clear_event_tags(
    request: RouteRequest,
    event_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> DeleteResponse:
    """Removes all tags from an event"""
    query = """
    WITH check_event AS (
        SELECT 1 FROM events
        WHERE id = $1
    ), delete_event_tags AS (
        DELETE FROM event_tags
        WHERE event_id = $1
    )
    SELECT EXISTS (SELECT 1 FROM check_event) AS exists;
    """
    exists = await request.app.pool.fetchval(query, event_id)
    if not exists:
        raise NotFoundError
    return DeleteResponse()


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
            msg = "Event does not exist"
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
        except asyncpg.ForeignKeyViolationError:
            await tr.rollback()
            msg = "Event or member no longer exists"
            raise NotFoundError(msg)
        else:
            await tr.commit()
            return JoinResponse()


class VerifyFailedResponse(ErrorResponse, frozen=True):
    message: str = "Failed to verify, entirely invalid hash"


class VerifyRequest(BaseModel, frozen=True):
    code: Annotated[str, Field(pattern=_NO_NULL_REGEX)]

    @model_validator(mode="after")
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
        409: {"model": ConflictResponse},
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
    WHERE events.id = $2 AND substring(event_attendance_codes.attendance_code for 8) = $1;
    """
    record = await request.app.pool.fetchrow(query, req.code, event_id)
    if not record:
        raise NotFoundError(detail="Unknown or invalid attendance code.")

    zone = EventTimezone(pool=request.app.pool)

    now = datetime.datetime.now(await zone.get_tzinfo(event_id))

    # As of now, the buffer times for registering would be:
    # - between the start and end at times
    # - one our before the event
    window_open = record["start_at"] + relativedelta(hours=-1)
    if not (window_open <= now <= record["end_at"]):
        msg = "You must verify your hash either during the event or one hour beforehand. Please try again."
        raise ConflictError(msg)

    # should raise a error directly, which would need to be handled.
    if request.app.ph.verify(record["attendance_hash"], str(event_id)):
        verify_query = """
        WITH check_prior AS (
            SELECT attended FROM events_members
            WHERE event_id = $1 AND member_id = $2
        ), upsert AS (
            INSERT INTO events_members (event_id, member_id, attended)
            VALUES ($1, $2, TRUE)
            ON CONFLICT (event_id, member_id) DO UPDATE
            SET attended = EXCLUDED.attended
        )
        SELECT COALESCE((SELECT attended FROM check_prior), FALSE) AS already_attended;
        """
        already_attended = await request.app.pool.fetchval(
            verify_query, event_id, session.identity.id
        )
        if already_attended:
            msg = "Attendance was already recorded"
            raise ConflictError(msg)

    return SuccessResponse(message="Successfully verified attendance!")


class AttendanceMember(BaseModel, frozen=True):
    id: uuid.UUID
    name: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    planned: Optional[bool] = None
    attended: bool


@router.get(
    "/events/{event_id}/attendance",
    dependencies=[has_permissions(Event.edit)],
    responses={
        200: {"model": KanaePages[AttendanceMember]},
        403: {"model": ForbiddenResponse},
    },
)
async def list_event_attendance(
    request: RouteRequest,
    event_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
    *,
    params: Annotated[KanaeParams, Depends()],
) -> KanaePages[AttendanceMember]:
    """Roster of members who planned/attended an event. Organizer-gated."""
    query = """
    SELECT members.id, members.name, events_members.planned, events_members.attended
    FROM events_members
    JOIN members ON members.id = events_members.member_id
    WHERE events_members.event_id = $1
    ORDER BY members.name
    """
    return await paginate(request.app.pool, query, event_id, params=params)  # ty: ignore[invalid-return-type]


class AttendanceCodeResponse(BaseModel, frozen=True):
    code: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


@router.get(
    "/events/{event_id}/attendance-code",
    dependencies=[has_permissions(Event.edit)],
    responses={
        200: {"model": AttendanceCodeResponse},
        404: {"model": NotFoundResponse},
    },
)
@router.limiter.limit("30/minute")
async def get_attendance_code(
    request: RouteRequest,
    event_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> AttendanceCodeResponse:
    """Returns the event's attendance code so the organizer can render a QR."""
    query = "SELECT attendance_code FROM event_attendance_codes WHERE event_id = $1;"
    row = await request.app.pool.fetchrow(query, event_id)
    if not row:
        raise NotFoundError

    # We only need to match the first 8 characters
    return AttendanceCodeResponse(code=row["attendance_code"][:8])


@router.delete(
    "/events/{event_id}/attendance/{member_id}",
    dependencies=[has_permissions(Event.edit)],
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("10/minute")
async def remove_attendance(
    request: RouteRequest,
    event_id: uuid.UUID,
    member_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> DeleteResponse:
    """Clears a member's attended flag for an event (keeps their RSVP)."""
    query = """
    UPDATE events_members
    SET attended = FALSE
    WHERE event_id = $1 AND member_id = $2
    RETURNING member_id;
    """
    row = await request.app.pool.fetchrow(query, event_id, member_id)
    if not row:
        raise NotFoundError
    return DeleteResponse()
