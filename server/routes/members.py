from pydantic import BaseModel
from utils.request import RouteRequest
from utils.router import KanaeRouter
from utils.errors import NotFoundException
import uuid

router = KanaeRouter(tags=["Members"])



class Members(BaseModel):
    name: str



@router.get("/members/{id}", name="Get Members")
async def get_members(request: RouteRequest, id: uuid.UUID):
    query = """
            SELECT name
            FROM members
            """
    
    members = await request.app.pool.fetchrow(query, id)

    if not members:
        raise NotFoundException()
    
    return Members(**dict(members))



# TODO: Update member by id



# TODO: Delete member by id