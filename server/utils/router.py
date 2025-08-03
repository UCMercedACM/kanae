from pathlib import Path

from fastapi import APIRouter
from utils.limiter import KanaeLimiter
from utils.limiter.utils import get_remote_address

from .config import KanaeConfig

CONFIG_PATH = Path(__file__).parents[1] / "config.yml"


class KanaeRouter(APIRouter):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)

        # This isn't my favorite implementation, but will do for now - Noelle
        self._config = KanaeConfig(CONFIG_PATH)
        self.limiter: KanaeLimiter = KanaeLimiter(
            get_remote_address, config=self._config
        )
