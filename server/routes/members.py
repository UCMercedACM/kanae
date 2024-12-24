from pydantic import BaseModel
from utils.request import RouteRequest
from utils.router import KanaeRouter
from utils.errors import NotFoundException
import uuid

router = KanaeRouter(tags=["Members"])



class Members(BaseModel):
    name: str



# Endpoint for getting members by their id
@router.get("/members/{id}", name="Get Members")
async def get_members(request: RouteRequest, id: uuid.UUID) -> Members:
    query = """
            SELECT name
            FROM members
            WHERE id = $1
            """
    
    member = await request.app.pool.fetchrow(query, id)

    if not member:
        raise NotFoundException()
    
    return Members(**dict(member))



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
    
    member = await request.app.pool.fetchrow(query, id, name)

    if not member:
        raise NotFoundException()
    
    return Members(**dict(member))