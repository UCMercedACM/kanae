from pydantic import BaseModel
from utils.request import RouteRequest
from utils.router import KanaeRouter


class NotFound(BaseModel):
    error: str = "Resource not found"


class GetUser(BaseModel):
    user: str


router = KanaeRouter(prefix="/users", tags=["Users"])


@router.get(
    "/get",
    response_model=GetUser,
    responses={200: {"model": GetUser}, 404: {"model": NotFound}},
    name="Get users",
)
@router.limiter.limit("1/minute")
async def get_users(request: RouteRequest) -> GetUser:
    query = "SELECT 1;"
    status = await request.app.pool.execute(query)
    return GetUser(user=status)
