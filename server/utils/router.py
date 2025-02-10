from pathlib import Path

from fastapi import APIRouter
from pydantic import BaseModel
from slowapi import Limiter
from slowapi.util import get_remote_address

from .config import KanaeConfig

CONFIG_PATH = Path(__file__).parents[1] / "config.yml"


class PartialConfig(BaseModel, frozen=True):
    redis_uri: str
    ratelimits: list[str]
    dev_mode: bool = False


class KanaeRouter(APIRouter):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)

        # This isn't my favorite implementation, but will do for now - Noelle
        self._config = self._load_config()
        self.limiter: Limiter = Limiter(
            key_func=get_remote_address,
            storage_uri=self._config.redis_uri,
            default_limits=self._config.ratelimits,  # type: ignore
            enabled=not self._config.dev_mode,
        )

    def _load_config(self) -> PartialConfig:
        config = KanaeConfig(CONFIG_PATH)
        return PartialConfig(
            redis_uri=config["redis_uri"],
            ratelimits=config["kanae"]["ratelimits"],
            dev_mode=config["kanae"]["dev_mode"],
        )
