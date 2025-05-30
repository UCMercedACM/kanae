from pathlib import Path

from core import Kanae
from fastapi_pagination import add_pagination
from routes import router
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from starlette.middleware.cors import CORSMiddleware
from supertokens_python import get_all_cors_headers
from supertokens_python.framework.fastapi import get_middleware
from utils.config import KanaeConfig, KanaeUvicornConfig
from utils.uvicorn.server import KanaeUvicornServer

config_path = Path(__file__).parent / "config.yml"
config = KanaeConfig(config_path)

app = Kanae(config=config)
app.add_middleware(get_middleware())
app.include_router(router)
app.add_middleware(
    CORSMiddleware,
    allow_origins=config["auth"]["allowed_origins"],
    allow_credentials=True,
    allow_methods=["GET", "PUT", "POST", "DELETE", "OPTIONS", "PATCH"],
    allow_headers=["Content-Type"] + get_all_cors_headers(),
)
add_pagination(app)
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)  # type: ignore
app.state.limiter = router.limiter


if __name__ == "__main__":
    config = KanaeUvicornConfig(
        "launcher:app",
        port=config["kanae"]["port"],
        host=config["kanae"]["host"],
        access_log=True,
    )

    server = KanaeUvicornServer(config)
    server.run()
