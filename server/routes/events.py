import datetime
import uuid
from dataclasses import asdict
from typing import Annotated, Literal, Optional, Union

import asyncpg
import base62
from argon2 import Parameters
from argon2.low_level import Type
from fastapi import Depends, Query, status
from fastapi.exceptions import HTTPException
from pydantic import BaseModel, model_validator
from supertokens_python.recipe.session import SessionContainer
from supertokens_python.recipe.session.framework.fastapi import verify_session
from typing_extensions import Self
from utils.errors import HTTPExceptionMessage, NotFoundException, NotFoundMessage
from utils.pages import KanaePages, KanaeParams, paginate
from utils.request import RouteRequest
from utils.responses import JoinResponse, VerifyFailedResponse
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


class Events(BaseModel):
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


class EventsWithCreatorID(Events):
    creator_id: uuid.UUID


class EventsWithID(Events):
    id: uuid.UUID


class EventsWithAllID(Events):
    creator_id: uuid.UUID
    id: uuid.UUID


@router.get("/events")
async def list_events(
    request: RouteRequest,
    name: Annotated[Optional[str], Query(min_length=3)] = None,
    *,
    params: Annotated[KanaeParams, Depends()],
) -> KanaePages[EventsWithAllID]:
    """Search a list of events"""
    query = """
    SELECT name, description, start_at, end_at, location, type, creator_id, id
    FROM events
    ORDER BY start_at DESC
    """

    if name:
        query = """
        SELECT name, description, start_at, end_at, location, type, creator_id, id
        FROM events
        WHERE name % $1
        ORDER BY similarity(name, $1) DESC
        """

    args = (name) if name else ()
    return await paginate(request.app.pool, query, *args, params=params)


@router.get(
    "/events/{id}",
    responses={200: {"model": EventsWithCreatorID}, 404: {"model": NotFoundMessage}},
)
async def get_event(request: RouteRequest, id: uuid.UUID) -> EventsWithCreatorID:
    """Retrieve event details via ID"""
    query = """
    SELECT name, description, start_at, end_at, location, type, creator_id
    FROM events
    WHERE id = $1;
    """

    rows = await request.app.pool.fetchrow(query, id)
    if not rows:
        raise NotFoundException
    return EventsWithCreatorID(**dict(rows))


class ModifiedEvent(BaseModel):
    name: str
    description: str
    location: str


class ModifiedEventWithDatetime(ModifiedEvent):
    start_at: datetime.datetime
    end_at: datetime.datetime


@router.put(
    "/events/{id}",
    responses={200: {"model": EventsWithID}, 404: {"model": NotFoundMessage}},
)
@has_any_role("admin", "leads")
@router.limiter.limit("10/minute")
async def edit_event(
    request: RouteRequest,
    id: uuid.UUID,
    req: Union[ModifiedEvent, ModifiedEventWithDatetime],
    session: Annotated[SessionContainer, Depends(verify_session())],
) -> EventsWithID:
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
            end_at = $7
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

        return EventsWithID(**dict(rows))


class DeleteResponse(BaseModel, frozen=True):
    message: str = "ok"


@router.delete(
    "/events/{id}",
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundMessage}},
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
    responses={200: {"model": EventsWithAllID}, 409: {"model": HTTPExceptionMessage}},
)
@has_any_role("admin", "leads")
@router.limiter.limit("15/minute")
async def create_events(
    request: RouteRequest,
    req: Events,
    session: Annotated[SessionContainer, Depends(verify_session())],
) -> EventsWithAllID:
    """Creates a new event given the provided data"""
    query = """
    INSERT INTO events (name, description, start_at, end_at, location, type, creator_id)
    VALUES ($1, $2, $3, $4, $5, $6, $7)
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
            raise HTTPException(
                detail="Requested project already exists",
                status_code=status.HTTP_409_CONFLICT,
            )
        else:
            await tr.commit()
            return EventsWithAllID(**dict(rows))


@router.post(
    "/events/{id}/join",
    responses={
        200: {"model": JoinResponse},
        404: {"model": NotFoundMessage},
        409: {"model": HTTPExceptionMessage},
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
        tr = connection.transaction

        rows = await connection.fetchrow(query, id)
        if not rows:
            raise NotFoundException("Should not happen")

        # TODO: Check to make sure that you can't join an event after the end time.
        await tr.start()

        try:
            await connection.execute(insert_query, id, session.get_user_id())
        except asyncpg.UniqueViolationError:
            await tr.rollback()
            raise HTTPException(
                detail="Authenticated member has already joined the requested event",
                status_code=status.HTTP_409_CONFLICT,
            )
        else:
            await tr.commit()
            return JoinResponse()


class VerifiedResponse(BaseModel):
    message: str = "Successfully verified attendance!"


class VerifyRequest(BaseModel):
    code: str

    @model_validator(mode="before")
    def check_code_length(self) -> Self:
        if len(self.code) > 8:
            raise ValueError("Must be 8 characters or less")
        return self


@router.post(
    "/events/{id}/verify",
    responses={200: {"model": VerifiedResponse}, 403: {"model": VerifyFailedResponse}},
)
@router.limiter.limit("5/second")
async def verify_attendance(
    request: RouteRequest,
    id: uuid.UUID,
    req: VerifyRequest,
    session: Annotated[SessionContainer, Depends(verify_session())],
):
    """Verify an authenticated user's attendance to the requested event"""
    query = "SELECT attendance_hash FROM events WHERE substring(attendance_code for 8) = $1;"
    possible_hash = await request.app.pool.fetchval(query, req.code)
    if not possible_hash:
        raise NotFoundException(
            detail="Apparently there is no attendance hash... Hmmmm.... this should never happen"
        )

    full_hash = compile_params(request.app.ph._parameters) + possible_hash

    # should raise a error directly, which would need to be handled.
    if request.app.ph.verify(full_hash, str(id)):
        verify_query = """
        INSERT INTO events_members (event_id, member_id, attended)
        VALUES ($1, $2, TRUE)
        ON CONFLICT (event_id, member_id) DO UPDATE
        SET attended = excluded.attended;
        """
        await request.app.pool.execute(verify_query, id, session.get_user_id())

    return VerifiedResponse()
