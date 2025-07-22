from pathlib import Path

from core import Kanae
from fastapi_pagination import add_pagination
from routes import router
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
app.state.limiter = router.limiter

if app.is_prometheus_enabled:
    app.instrumentator.add_middleware()


if __name__ == "__main__":
    config = KanaeUvicornConfig(
        "launcher:app",
        port=config["kanae"]["port"],
        host=config["kanae"]["host"],
        workers=2,
        access_log=True,
    )

    server = KanaeUvicornServer(config)
    server.run()
