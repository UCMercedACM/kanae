from pydantic import BaseModel
from typing import Annotated, Union
from utils.request import RouteRequest
from utils.router import KanaeRouter
from typing import Optional, Literal
from utils.errors import NotFoundException, NotFoundMessage
from fastapi import Query
import datetime
import uuid

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


# TODO: Pagination the responses
@router.get("/events")
async def list_events(
    request: RouteRequest,
    name: Annotated[Optional[str], Query(min_length=3)] = None,
    limit: Annotated[int, Query(gt=0, le=100)] = 50,
) -> list[Events]:
    """Search a list of events"""
    query = """
    SELECT id, name, description, start_at, end_at, location, type
    FROM events
    ORDER BY start_at DESC
    LIMIT $1;
    """

    if name:
        query = """
        SELECT id, name, description, start_at, end_at, location, type
        FROM events
        WHERE name % $1
        ORDER BY similarity(name, $1) DESC
        LIMIT 10;
        """

    arg = name if name else limit
    rows = await request.app.pool.fetch(query, arg)

    return [Events(**record) for record in rows]


class EventsWithID(Events):
    id: uuid.UUID
    

@router.get(
    "/events/{id}",
    responses={200: {"model": EventsWithID}, 404: {"model": NotFoundMessage}},
)
async def get_event(request: RouteRequest, id: uuid.UUID) -> Events:
    """Retrieve event details via ID"""
    query = """
    SELECT name, description, start_at, end_at, location, type
    FROM events
    WHERE id = $1;
    """

    rows = await request.app.pool.fetchrow(query, id)
    if not rows:
        raise NotFoundException
    return Events(**dict(rows))

class ModifiedEvent(BaseModel):
    name: str
    description: str
    location: str
    
class ModifiedEventWithDatetime(ModifiedEvent):
    start_at: datetime.datetime
    end_at: datetime.datetime
    
# Depends on auth and scopes
@router.put("/events/{id}", responses={200: {"model": EventsWithID}, 404: {"model": NotFoundMessage}})
async def edit_event(request: RouteRequest, id: uuid.UUID, req: Union[ModifiedEvent, ModifiedEventWithDatetime]):
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
            end_at = $6
        WHERE id = $1
        RETURNING *;
        """
    
    rows = await request.app.pool.fetchrow(query, id, *req.model_dump().values())
    if not rows:
        raise NotFoundException(detail="Resource cannot be updated") # Not sure if this is correct by RFC 9110 standards
    return EventsWithID(**dict(rows))
    
    
class DeleteResponse(BaseModel, frozen=True):
    message: str = "ok"
    
# Depends on auth and scopes
@router.delete("/events/{id}",
               responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundMessage}})
async def delete_event(request: RouteRequest, id: uuid.UUID) -> DeleteResponse:
    query = """
    DELETE FROM events
    WHERE id = $1;
    """
    
    status = await request.app.pool.execute(query, id)
    if status[-1] == "0":
        raise NotFoundException
    return DeleteResponse()

# Depends on auth and scopes
@router.post("/events/create", responses={200: {"model": EventsWithID}})
async def create_events(request: RouteRequest, req: Events) -> EventsWithID:
    """Create a new event"""
    query = """
    INSERT INTO events (name, description, start_at, end_at, location, type)
    VALUES ($1, $2, $3, $4, $5, $6)
    RETURNING *;
    """
    rows = await request.app.pool.fetchrow(query, *req.model_dump().values())
    return EventsWithID(**dict(rows))

# We need the member endpoints to be finished in order to implement this
# Depends on auth
@router.post("/events/join")
async def join_event(request: RouteRequest):
    ...