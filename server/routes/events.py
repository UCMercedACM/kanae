from pydantic import BaseModel
from typing import Annotated
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
    query = """
    SELECT name, description, start_at, end_at, location, type
    FROM events
    WHERE id = $1;
    """

    rows = await request.app.pool.fetchrow(query, id)
    if not rows:
        raise NotFoundException
    return Events(**dict(rows))


# TODO: Enforce status codes if the event is unique, etc
@router.post("/events/create")
async def create_events(request: RouteRequest, req: Events) -> Events:
    query = """
    INSERT INTO events (name, description, start_at, end_at, location, type)
    VALUES ($1, $2, $3, $4, $5, $6);
    """
    event_req = req.model_dump()
    await request.app.pool.execute(query, *event_req.values())
    return req
