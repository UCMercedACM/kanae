from pydantic import BaseModel
from utils.request import RouteRequest
from utils.router import KanaeRouter
from typing import Optional, Literal
from utils.errors import NotFoundException
import datetime
import uuid

router = KanaeRouter(tags=["Events"])


class Events(BaseModel):
    name: str
    description: str
    start_at: datetime.datetime
    end_at: datetime.datetime
    location: str
    alt_link: Optional[str] = None
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


# TODO: Ensure that the limits for how much can be requested is in place
@router.get("/events", name="List events")
async def events_list(request: RouteRequest) -> list[Events]:
    query = """
    SELECT name, description, start_at, end_at, location, alt_link, type
    FROM events
    WHERE created_at >= (NOW() - INTERVAL '12 hours');
    """
    rows = await request.app.pool.fetch(query)
    return [Events(**record) for record in rows]


# TODO: Enforce status codes if the event is unique, etc
@router.post("/events/create", name="Create Events")
async def events_create(request: RouteRequest, req: Events) -> Events:
    query = """
    INSERT INTO events (name, description, start_at, end_at, location, alt_link, type)
    VALUES ($1, $2, $3, $4, $5, $6, $7);
    """
    event_req = req.model_dump()
    await request.app.pool.execute(query, *event_req.values())
    return req


@router.get("/events/{id}", name="Get event", responses={200: {"model": Events}})
async def get_event(request: RouteRequest, id: uuid.UUID) -> Events:
    query = """
    SELECT name, description, start_at, end_at, location, alt_link, type
    FROM events
    WHERE id = $1;
    """

    rows = await request.app.pool.fetchrow(query, id)
    if not rows:
        raise NotFoundException()
    return Events(**dict(rows))
