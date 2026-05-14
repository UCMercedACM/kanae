from fastapi_pagination import add_pagination
from starlette.middleware.cors import CORSMiddleware

from core import Kanae, KanaeConfig, find_config
from routes import router

config = KanaeConfig.load_from_file(find_config())


app = Kanae(config=config)
app.include_router(router)
app.add_middleware(
    CORSMiddleware,
    allow_origins=config.kanae.allowed_origins,
    allow_credentials=True,
    allow_methods=["GET", "PUT", "POST", "DELETE", "OPTIONS", "PATCH"],
    allow_headers=["Content-Type"],
)
add_pagination(app)
app.limiter = router.limiter

if app.is_prometheus_enabled:
    app.instrumentator.add_middleware()
