from __future__ import annotations

from fastapi import APIRouter

from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.middleware import SlowAPIMiddleware
from slowapi.errors import RateLimitExceeded
from typing import TYPE_CHECKING
from pathlib import Path
from .config import KanaeConfig

# There isn't really a good solution to this except to do this
# I really hate doing this but oh well
config_path = Path(__file__).parents[1] / "config.yml"
config = KanaeConfig(config_path)

class KanaeRouter(APIRouter):
    limiter: Limiter
    
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.limiter = Limiter(key_func=get_remote_address, storage_uri=config["redis_uri"])
        
        
        
        
    