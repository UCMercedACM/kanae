from __future__ import annotations

import time
from typing import TYPE_CHECKING, Optional, cast

from glide import (
    GlideClient,
    Script,
)
from glide_shared.exceptions import GlideError
from limits.aio.storage import MovingWindowSupport, SlidingWindowCounterSupport, Storage
from limits.util import get_package_data

if TYPE_CHECKING:
    from utils.glide import GlideManager


class ValkeyStorage(Storage, MovingWindowSupport, SlidingWindowCounterSupport):
    """Rate limit storage backend by Valkey GLIDE

    Note that the underlying client connection (`glide.GlideClient`) is owned by
    `GlideManager`, which is attached at runtime
    """

    PREFIX = "LIMITS"

    RES_DIR = "resources/redis/lua_scripts"

    SCRIPT_MOVING_WINDOW = get_package_data(f"{RES_DIR}/moving_window.lua")
    SCRIPT_ACQUIRE_MOVING_WINDOW = get_package_data(
        f"{RES_DIR}/acquire_moving_window.lua"
    )
    SCRIPT_CLEAR_KEYS = get_package_data(f"{RES_DIR}/clear_keys.lua")
    SCRIPT_INCR_EXPIRE = get_package_data(f"{RES_DIR}/incr_expire.lua")
    SCRIPT_SLIDING_WINDOW = get_package_data(f"{RES_DIR}/sliding_window.lua")
    SCRIPT_ACQUIRE_SLIDING_WINDOW = get_package_data(
        f"{RES_DIR}/acquire_sliding_window.lua"
    )

    def __init__(
        self,
        uri: str,
        *,
        key_prefix: str = PREFIX,
        wrap_exceptions: bool = False,
    ) -> None:
        """
        Args:
            uri: uri of the form used by `GlideManager`. Retained for
                conformance with `limits.aio.storage.Storage`; the actual
                client configuration is owned by the attached manager.
            key_prefix: the prefix for each key created in redis.
            wrap_exceptions: Whether to wrap storage exceptions in
                `limits.errors.StorageError` before raising it.
        """
        super().__init__(uri, wrap_exceptions=wrap_exceptions)

        self.uri = uri
        self.key_prefix = key_prefix
        self._manager: Optional[GlideManager] = None

        self.lua_moving_window = Script(self.SCRIPT_MOVING_WINDOW)
        self.lua_acquire_moving_window = Script(self.SCRIPT_ACQUIRE_MOVING_WINDOW)
        self.lua_clear_keys = Script(self.SCRIPT_CLEAR_KEYS)
        self.lua_incr_expire = Script(self.SCRIPT_INCR_EXPIRE)
        self.lua_sliding_window = Script(self.SCRIPT_SLIDING_WINDOW)
        self.lua_acquire_sliding_window = Script(self.SCRIPT_ACQUIRE_SLIDING_WINDOW)

    @property
    def base_exceptions(
        self,
    ) -> type[Exception] | tuple[type[Exception], ...]:
        return (GlideError,)

    @property
    def client(self) -> GlideClient:
        if self._manager is None:
            msg = "RedisStorage has no GlideManager attached."
            raise RuntimeError(msg)
        return self._manager.client

    def _prefixed_key(self, key: str) -> str:
        return f"{self.key_prefix}:{key}"

    def _current_window_key(self, key: str) -> str:
        return f"{{{key}}}"

    def _previous_window_key(self, key: str) -> str:
        return f"{self._current_window_key(key)}/-1"

    def attach(self, manager: GlideManager) -> None:
        """Bind an entered `GlideManager` to this storage.

        Args:
            manager: the entered `GlideManager` that owns the underlying
                `GlideClient` connection.
        """
        self._manager = manager

    async def incr(self, key: str, expiry: int, amount: int = 1) -> int:
        """Increments the counter for a given rate limit key.

        Args:
            key: the key to increment.
            expiry: amount in seconds for the key to expire in.
            amount: the number to increment by.

        Returns:
            The new counter value after incrementing.
        """
        prefixed = self._prefixed_key(key)
        result = await self.client.invoke_script(
            self.lua_incr_expire,
            keys=[prefixed],
            args=[str(expiry), str(amount)],
        )
        return cast("int", result)

    async def get(self, key: str) -> int:
        """Get the current counter value for a rate limit key.

        Args:
            key: the key to get the counter value for.

        Returns:
            The current counter value, or 0 if the key does not exist.
        """
        value = await self.client.get(self._prefixed_key(key))
        return int(value or 0)

    async def clear(self, key: str) -> None:
        """Clear rate limit state for a key.

        Args:
            key: the key to clear rate limits for.
        """
        await self.client.delete([self._prefixed_key(key)])

    async def acquire_entry(
        self, key: str, limit: int, expiry: int, amount: int = 1
    ) -> bool:
        """Attempt to acquire an entry in a moving window.

        Args:
            key: rate limit key to acquire an entry in.
            limit: amount of entries allowed.
            expiry: expiry of the entry.
            amount: the number of entries to acquire.

        Returns:
            `True` if the entry was acquired, `False` otherwise.
        """
        prefixed = self._prefixed_key(key)
        timestamp = time.time()
        acquired = await self.client.invoke_script(
            self.lua_acquire_moving_window,
            keys=[prefixed],
            args=[str(timestamp), str(limit), str(expiry), str(amount)],
        )
        return bool(acquired)

    async def get_moving_window(
        self, key: str, limit: int, expiry: int
    ) -> tuple[float, int]:
        """Return the starting point and number of entries in the moving window.

        Args:
            key: rate limit key.
            limit: amount of entries allowed.
            expiry: expiry of entry.

        Returns:
            A tuple of `(previous count, previous TTL, current count, current TTL)`.
        """
        prefixed = self._prefixed_key(key)
        timestamp = time.time()
        window = await self.client.invoke_script(
            self.lua_moving_window,
            keys=[prefixed],
            args=[str(timestamp - expiry), str(limit)],
        )
        if window:
            window = cast("list[str]", window)
            return float(window[0]), int(window[1])
        return timestamp, 0

    async def acquire_sliding_window_entry(
        self,
        key: str,
        limit: int,
        expiry: int,
        amount: int = 1,
    ) -> bool:
        """Attempt to acquire an entry in a sliding window.

        Args:
            key: rate limit key to acquire an entry in.
            limit: amount of entries allowed.
            expiry: expiry of the entry.
            amount: the number of entries to acquire.

        Returns:
            `True` if the entry was acquired, `False` otherwise.
        """
        previous_key = self._prefixed_key(self._previous_window_key(key))
        current_key = self._prefixed_key(self._current_window_key(key))
        acquired = await self.client.invoke_script(
            self.lua_acquire_sliding_window,
            keys=[previous_key, current_key],
            args=[str(limit), str(expiry), str(amount)],
        )
        return bool(acquired)

    async def get_sliding_window(
        self, key: str, expiry: int
    ) -> tuple[int, float, int, float]:
        """Return the counts and TTLs for the previous and current sliding windows.

        Args:
            key: rate limit key.
            expiry: expiry of the window.

        Returns:
            A tuple of `(previous count, previous TTL, current count, current TTL)`.
        """
        previous_key = self._prefixed_key(self._previous_window_key(key))
        current_key = self._prefixed_key(self._current_window_key(key))
        window = await self.client.invoke_script(
            self.lua_sliding_window,
            keys=[previous_key, current_key],
            args=[str(expiry)],
        )
        if window:
            window = cast("list[str]", window)
            return (
                int(window[0] or 0),
                max(0, float(window[1] or 0)) / 1000,
                int(window[2] or 0),
                max(0, float(window[3] or 0)) / 1000,
            )
        return 0, 0.0, 0, 0.0

    async def clear_sliding_window(self, key: str, expiry: int) -> None:
        """Clear the previous and current sliding window entries for a key.

        Args:
            key: rate limit key to clear.
            expiry: expiry of the window.
        """
        previous_key = self._prefixed_key(self._previous_window_key(key))
        current_key = self._prefixed_key(self._current_window_key(key))
        await self.client.delete([previous_key, current_key])

    async def get_expiry(self, key: str) -> float:
        """Get the absolute expiry timestamp for a rate limit key.

        Args:
            key: the key to get the expiry for.

        Returns:
            The absolute expiry timestamp (seconds since epoch).
        """
        ttl = await self.client.ttl(self._prefixed_key(key))
        return max(ttl, 0) + time.time()

    async def check(self) -> bool:
        """Check if storage is healthy by calling `PING`.

        Returns:
            `True` if the storage responded to `PING`, `False` otherwise.
        """
        try:
            await self.client.ping()
        except GlideError:
            return False
        else:
            return True

    async def reset(self) -> Optional[int]:
        """Delete all keys prefixed with `key_prefix` in blocks of 5000.

        Warning:
            Intended to be fast but not validated on very large datasets —
            use with care.

        Returns:
            The number of keys deleted.
        """
        result = await self.client.invoke_script(
            self.lua_clear_keys,
            keys=[self._prefixed_key("*")],
            args=[],
        )
        return cast("int", result)
