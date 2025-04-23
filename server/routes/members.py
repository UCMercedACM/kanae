import datetime
import uuid
from typing import Annotated, Literal, Optional

from fastapi import Depends
from pydantic import BaseModel
from supertokens_python.recipe.session import SessionContainer
from supertokens_python.recipe.session.framework.fastapi import verify_session
from utils.errors import NotFoundException, NotFoundMessage
from utils.request import RouteRequest
from utils.router import KanaeRouter

router = KanaeRouter(tags=["Members"])


class ClientEvents(BaseModel, frozen=True):
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


class ClientProjects(BaseModel, frozen=True):
    id: uuid.UUID
    name: str
    description: str
    link: str
    type: Literal[
        "independent",
        "sig_ai",
        "sig_swe",
        "sig_cyber",
        "sig_data",
        "sig_arch",
        "sig_graph",
    ]
    active: bool
    founded_at: datetime.datetime


class ClientMember(BaseModel, frozen=True):
    id: uuid.UUID
    name: str
    created_at: datetime.datetime
    projects: list[ClientProjects]
    events: list[ClientEvents]


@router.get(
    "/members/me",
    responses={200: {"model": ClientMember}, 404: {"model": NotFoundMessage}},
)
async def get_logged_member(
    request: RouteRequest,
    session: Annotated[SessionContainer, Depends(verify_session())],
) -> ClientMember:
    """Obtain details pertaining to the currently authenticated user"""
    query = """
    SELECT members.id,
        members.name,
        members.created_at,
        jsonb_agg_strict(projects.*) AS projects,
        jsonb_agg_strict(
            jsonb_build_object(
                'id',
                events.id,
                'name',
                events.name,
                'description',
                events.description,
                'start_at',
                events.start_at,
                'end_at',
                events.end_at,
                'location',
                events.location,
                'type',
                events.type,
                'timezone',
                events.timezone
            )
        ) AS events
    FROM members
        INNER JOIN project_members ON members.id = project_members.member_id
        INNER JOIN projects ON project_members.project_id = projects.id
        INNER JOIN events_members ON members.id = events_members.member_id
        INNER JOIN events ON events_members.event_id = events.id
    WHERE members.id = $1
    GROUP BY members.id;
    """
    rows = await request.app.pool.fetchrow(query, session.get_user_id())
    if not rows:
        raise NotFoundException
    return ClientMember(**(dict(rows)))


@router.get("/members/me/projects", responses={200: {"model": ClientProjects}})
async def get_logged_projects(
    request: RouteRequest,
    session: Annotated[SessionContainer, Depends(verify_session())],
    since: Optional[datetime.datetime] = None,
) -> list[ClientProjects]:
    """Obtains projects associated with the currently authenticated member, with options to sort"""
    args = [session.get_user_id()]

    query = """
    SELECT projects.*
    FROM members
        INNER JOIN project_members ON members.id = project_members.member_id
        INNER JOIN projects ON project_members.project_id = projects.id
    WHERE members.id = $1
    GROUP BY projects.id;
    """

    if since:
        query = """
        SELECT projects.*
        FROM members
            INNER JOIN project_members ON members.id = project_members.member_id 
            AND project_members.joined_at >= $2
            INNER JOIN projects ON project_members.project_id = projects.id
        WHERE members.id = $1
        GROUP BY projects.id;
        """
        args.append(since)  # type: ignore

    rows = await request.app.pool.fetch(query, *args)
    return [ClientProjects(**dict(record)) for record in rows]


@router.get("/members/me/events")
async def get_logged_events(
    request: RouteRequest,
    session: Annotated[SessionContainer, Depends(verify_session())],
    planned: Optional[bool] = None,
    attended: Optional[bool] = None,
) -> list[ClientEvents]:
    """Obtains events associated with the currently authenticated member.

    Note that using both `planned` and `attended` queries would result in events that have been planned and attended
    (i.e., both queries would be used to search for an AND query)
    """
    constraint = ""

    if planned and attended:
        constraint = (
            "AND events_members.planned = true AND events_members.attended = true"
        )

    if planned:
        constraint = "AND events_members.planned = true"
    elif attended:
        constraint = "AND events_members.attended = true"

    # ruff: noqa: S608
    # This error says "possible SQL injection", but the variables are not passed in to the query directly
    # Instead, they are used to check for the constraint query
    query = f"""
    SELECT events.id, events.name, events.description, events.start_at, events.end_at, events.location, events.type, events.timezone
    FROM members
        INNER JOIN events_members ON members.id = events_members.member_id {constraint}
        INNER JOIN events ON events_members.event_id = events.id
    WHERE members.id = $1
    GROUP BY events.id;
    """
    rows = await request.app.pool.fetch(query, session.get_user_id())
    return [ClientEvents(**dict(record)) for record in rows]


class ModifiedClient(BaseModel, frozen=True):
    name: Optional[str] = None
    email: Optional[str] = None
    password: Optional[str] = None
