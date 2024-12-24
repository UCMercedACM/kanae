import datetime
import uuid
from typing import Annotated, Literal, Optional, Union

from fastapi import Depends, Query
from pydantic import BaseModel
from supertokens_python.recipe.session import SessionContainer
from supertokens_python.recipe.session.framework.fastapi import verify_session
from utils.errors import NotFoundException, NotFoundMessage
from utils.pages import KanaePages, KanaeParams, paginate
from utils.request import RouteRequest
from utils.router import KanaeRouter

router = KanaeRouter(tags=["Events"])


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


# Depends on scopes
@router.put(
    "/events/{id}",
    responses={200: {"model": EventsWithID}, 404: {"model": NotFoundMessage}},
)
@router.limiter.limit("10/minute")
async def edit_event(
    request: RouteRequest,
    id: uuid.UUID,
    req: Union[ModifiedEvent, ModifiedEventWithDatetime],
    session: SessionContainer = Depends(verify_session),
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

    rows = await request.app.pool.fetchrow(
        query, id, session.get_user_id(), *req.model_dump().values()
    )
    if not rows:
        raise NotFoundException(
            detail="Resource cannot be updated"
        )  # Not sure if this is correct by RFC 9110 standards
    return EventsWithID(**dict(rows))


class DeleteResponse(BaseModel, frozen=True):
    message: str = "ok"


# Depends on scopes
@router.delete(
    "/events/{id}",
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundMessage}},
)
@router.limiter.limit("10/minute")
async def delete_event(
    request: RouteRequest,
    id: uuid.UUID,
    session: SessionContainer = Depends(verify_session),
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


# Depends on scopes
@router.post("/events/create", responses={200: {"model": EventsWithAllID}})
@router.limiter.limit("15/minute")
async def create_events(
    request: RouteRequest,
    req: EventsWithCreatorID,
    session: SessionContainer = Depends(verify_session),
) -> EventsWithAllID:
    """Creates a new event given the provided data"""
    query = """
    INSERT INTO events (name, description, start_at, end_at, location, type, creator_id)
    VALUES ($1, $2, $3, $4, $5, $6, $7)
    RETURNING *;
    """
    rows = await request.app.pool.fetchrow(
        query, *req.model_dump().values(), session.get_user_id()
    )
    return EventsWithAllID(**dict(rows))


# We need the member endpoints to be finished in order to implement this
# Depends on auth
@router.post("/events/join")
async def join_event(
    request: RouteRequest, session: SessionContainer = Depends(verify_session)
): ...
