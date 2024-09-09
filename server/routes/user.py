from fastapi import APIRouter
from pydantic import BaseModel
from utils.request import RouteRequest


class NotFound(BaseModel):
    error: str = "Resource not found"


class GetUser(BaseModel):
    user: str


router = APIRouter(prefix="/users", tags=["Users"])


@router.get(
    "/get",
    response_model=GetUser,
    responses={200: {"model": GetUser}, 404: {"model": NotFound}},
    name="Get users",
)
async def get_users(request: RouteRequest) -> GetUser:
    query = "SELECT 1;"
    status = await request.app.pool.execute(query)
    return GetUser(user=status)
