from fastapi import APIRouter
from utils.limiter import KanaeLimiter
from utils.limiter.utils import get_remote_address

from .config import KanaeConfig, find_config


class KanaeRouter(APIRouter):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)

        # This isn't my favorite implementation, but will do for now - Noelle
        self._config = KanaeConfig.load_from_file(find_config())
        self.limiter: KanaeLimiter = KanaeLimiter(
            get_remote_address, config=self._config
        )
