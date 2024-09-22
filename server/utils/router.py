from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter
from slowapi import Limiter
from slowapi.util import get_remote_address

from .config import KanaeConfig

CONFIG_PATH = Path(__file__).parents[1] / "config.yml"


class KanaeRouter(APIRouter):
    limiter: Limiter

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._redis_uri = KanaeConfig(CONFIG_PATH)["redis_uri"]
        self.limiter = Limiter(key_func=get_remote_address, storage_uri=self._redis_uri)
