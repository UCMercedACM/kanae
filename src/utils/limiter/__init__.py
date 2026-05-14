"""Internal package that rewrites Slowapi to be entirely async"""

from .extension import KanaeLimiter as KanaeLimiter
from .utils import (
    get_ipaddr as get_ipaddr,
    get_remote_address as get_remote_address,
)
