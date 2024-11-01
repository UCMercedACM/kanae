from pydantic import BaseModel
from utils.request import RouteRequest
from utils.router import KanaeRouter
from typing import Optional, Literal
import datetime

router = KanaeRouter(tags=["Events"])


class BasicStruct(BaseModel):
    name: str


@router.get("/events", response_model=BasicStruct)
async def events_list(request: RouteRequest) -> BasicStruct:
    return BasicStruct(name="hij")


class EventsCreateRequest(BaseModel):
    name: str
    description: str
    start_at: datetime.datetime
    end_at: datetime.datetime
    location: str
    alt_link: Optional[str]
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


@router.post("/events/create", name="Create Events")
async def events_create(request: RouteRequest, req: EventsCreateRequest):
    query = """
    INSERT INTO events (name, description, start_at, end_at, location, type)
    VALUES ($1, $2, $3, $4, $5, $6);
    """
    await request.app.pool.execute(
        query,
        req.name,
        req.description,
        req.start_at,
        req.end_at,
        req.location,
        req.type,
    )
    return req
