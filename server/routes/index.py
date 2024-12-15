from fastapi.responses import RedirectResponse
from utils.router import KanaeRouter

router = KanaeRouter()


@router.get("/")
async def index() -> RedirectResponse:
    return RedirectResponse("/docs")
