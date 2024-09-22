import importlib
from pkgutil import iter_modules

from fastapi import APIRouter
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.middleware import SlowAPIMiddleware
from slowapi.errors import RateLimitExceeded
from utils.router import KanaeRouter

router = KanaeRouter()
route_modules = [module.name for module in iter_modules(__path__, f"{__package__}.")]

for route in route_modules:
    module = importlib.import_module(route)
    router.include_router(module.router)
