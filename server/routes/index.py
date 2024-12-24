from fastapi.responses import RedirectResponse
from utils.router import KanaeRouter

router = KanaeRouter()


@router.get("/", include_in_schema=False)
async def index() -> RedirectResponse:
    return RedirectResponse("/docs")
