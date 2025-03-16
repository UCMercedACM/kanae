import uuid

from events import EventsWithID
from projects import PartialProjects
from pydantic import BaseModel
from utils.errors import NotFoundException
from utils.request import RouteRequest
from utils.router import KanaeRouter

router = KanaeRouter(tags=["Members"])


class PartialMember(BaseModel):
    id: str
    name: str


class Member(BaseModel):
    name: str
    email: str
    projects: list[PartialProjects]
    events: list[EventsWithID]


class Members(BaseModel):
    name: str


# TODO: Figure out an more efficent way to join between the M to M tables in one go
# @router.get("/members/{id}")
# async def get_member(request: RouteRequest, id: uuid.UUID) -> None:


# Endpoint for deleting members by thier id
@router.delete("/members/{id}", name="Delete Members")
async def delete_members(request: RouteRequest, id: uuid.UUID, req: Members) -> Members:
    query = """
            DELETE
            FROM members
            WHERE id = $1
            """

    member = await request.app.pool.execute(query, id)

    if not member:
        raise NotFoundException()

    return req


# TODO: Update member by id
@router.put("/memers/{id}", name="Update Members")
async def update_members(request: RouteRequest, id: uuid.UUID, req: Members) -> Members:
    query = """
            UPDATE members
            SET
            name = $2
            WHERE id = $1
            RETURNING *
            """

    member = await request.app.pool.fetchrow(query, id, req.name)

    if not member:
        raise NotFoundException()

    return Members(**dict(member))
