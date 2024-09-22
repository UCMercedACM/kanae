import importlib
from pkgutil import iter_modules

from utils.router import KanaeRouter

router = KanaeRouter()
route_modules = [module.name for module in iter_modules(__path__, f"{__package__}.")]

for route in route_modules:
    module = importlib.import_module(route)
    router.include_router(module.router)
