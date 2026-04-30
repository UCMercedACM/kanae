import functools
import logging
from collections.abc import Awaitable, Callable, Iterable
from contextvars import ContextVar
from typing import Any, Concatenate, Optional, Protocol, Self, cast, overload

import orjson
from aiocache import cached
from aiocache.base import BaseCache
from aiocache.plugins import BasePlugin
from aiocache.serializers import JsonSerializer
from glide import (
    Batch,
    ConditionalChange,
    ExpirySet,
    ExpiryType,
    GlideClient,
)
from glide_shared.exceptions import (
    GlideError,
    RequestError as IncrbyException,
)
from pydantic import BaseModel, ValidationError

type TTLValue = int | float
type ValkeyValue = str | bytes | bytearray | memoryview


class _CachedMethodWrapper[S, **P, R]:
    """Replaces the decorated method on the class.

    Generic over the wrapped method's signature:
    - `S` is the bound instance type
    - `P` captures the remaining parameters
    - `R` is the return type

    This class acts as a descriptor — `__get__` returns a per-instance `_BoundCachedMethod` proxy
    that carries the `alru_cache`-styled management methods. At the class level it falls back to a
    direct callable for the rare `Cls.method(instance, ...)` form

    Args:
        dec ("cached_method"): Decorator (usually `@cached_method`) that is utilized
        func (Callable[Concatenate[S, P], Awaitable[R]]): Function that the decorator binds to
    """

    def __init__(
        self,
        dec: "cached_method",
        func: Callable[Concatenate[S, P], Awaitable[R]],
    ) -> None:
        self._dec = dec
        self._func = func
        functools.update_wrapper(self, func)

    async def __call__(self, instance: S, *args: P.args, **kwargs: P.kwargs) -> R:
        return await self._invoke(instance, *args, **kwargs)

    @overload
    def __get__(self, instance: None, _owner: Optional[type[S]] = None) -> Self: ...

    @overload
    def __get__(
        self,
        instance: S,
        _owner: Optional[type[S]] = None,
    ) -> "_BoundCachedMethod[S, P, R]": ...

    def __get__(
        self,
        instance: Optional[S],
        _owner: Optional[type[S]] = None,
    ) -> "Self | _BoundCachedMethod[S, P, R]":
        if instance is None:
            return self
        return _BoundCachedMethod(self, instance)

    async def _invoke(self, instance: S, *args: P.args, **kwargs: P.kwargs) -> R:
        token = self._dec._current_cache.set(
            getattr(instance, self._dec._cache_attr),
        )
        try:
            result = await self._dec.decorator(
                self._func,
                instance,
                *args,
                **kwargs,
            )
        finally:
            self._dec._current_cache.reset(token)
        return cast("R", result)


class _BoundCachedMethod[S, **P, R]:
    """Per-instance bound proxy returned by `_CachedMethodWrapper.__get__`

    Calling it invokes the underlying method through the cache; it also
    exposes `alru_cache`-styled management methods that operate on the cache
    bound to *this* instance. Generic parameters mirror
    `_CachedMethodWrapper`.
    """

    def __init__(
        self,
        wrapper: _CachedMethodWrapper[S, P, R],
        instance: S,
    ) -> None:
        self._wrapper = wrapper
        self._instance = instance

    async def __call__(self, *args: P.args, **kwargs: P.kwargs) -> R:
        return await self._wrapper._invoke(self._instance, *args, **kwargs)

    async def cache_invalidate(self, *args: P.args, **kwargs: P.kwargs) -> bool:
        """Invalidates cached entry for the providen args.

        I.e., it will delete the cached entry of the parent function/method.
        You must provide the same arguments as the parent function/method

        Returns:
            bool: Whether the cached entry is invalidated or not
        """
        cache = getattr(self._instance, self._wrapper._dec._cache_attr)
        key = self._wrapper._dec.get_cache_key(
            self._wrapper._func,
            (self._instance, *args),
            kwargs,
        )
        return bool(await cache.delete(key))

    async def cache_clear(self) -> bool:
        """Drop every entry in this cache's namespace.

        Returns:
            bool: Whether the cached entry is successfully cleared or not
        """
        cache = getattr(self._instance, self._wrapper._dec._cache_attr)
        return bool(await cache.clear(namespace=cache.namespace))

    def cache_info(self) -> BaseCache:
        """Returns underlying cache information

        Returns:
            BaseCache: Cache information
        """
        return getattr(self._instance, self._wrapper._dec._cache_attr)


class cached_method(cached):
    """Custom variant of aiocache's `@cached` decorator that resolves its cache from `self.<cache_attr>`

    This variant is styled just like `alru_cache`, thus exposing operations to invalidate, clear and obtain cache information.
    Operations are accessible using `instance.method.cache_invalidate()`, etc

    Args:
        cache_attr (str): Name of the attribute on the decorated method's
            instance that holds the `BaseCache` to use. Resolved at call time
            so every instance can carry its own cache.
        ttl (Optional[TTLValue]): Time-to-live for cached entries, in seconds.
            `None` disables expiration; aiocache's `set` will store the entry
            without a deadline. Defaults to `None`.
        key (Optional[str]): Fixed cache key that bypasses `key_builder` and
            the default arg-based key generation. Use when every call should
            map to the same cached entry regardless of arguments. Defaults to
            `None`.
        key_builder (Optional[Callable[..., str]]): Callable invoked as
            `key_builder(func, *args, **kwargs)` to produce the cache key
            string. When `None`, aiocache's default argument-hashing strategy
            is used. Defaults to `None`.
        skip_cache_func (Optional[Callable[[object], bool]]): Predicate that
            receives the wrapped method's return value and returns `True` to
            skip caching it (the value is still returned to the caller).
            When `None`, a constant-`False` filter is installed so every
            non-`None` return is cached. Defaults to `None`.
        noself (bool): Whether to omit the bound `self` from
            auto-generated cache keys. Only relevant when `key_builder` is
            `None`. Defaults to `False`.
    """

    _current_cache: ContextVar[BaseCache] = ContextVar("_cached_method_current_cache")

    def __init__(
        self,
        cache_attr: str,
        *,
        ttl: Optional[TTLValue] = None,
        key: Optional[str] = None,
        key_builder: Optional[Callable[..., str]] = None,
        skip_cache_func: Optional[Callable[[object], bool]] = None,
        noself: bool = False,
    ) -> None:
        super().__init__(
            ttl=ttl,
            key=key,
            key_builder=key_builder,
            skip_cache_func=skip_cache_func or (lambda _value: False),
            noself=noself,
        )
        self._cache_attr = cache_attr
        self._log = logging.getLogger("kanae.cache")

    def __call__[S, **P, R](
        self,
        f: Callable[Concatenate[S, P], Awaitable[R]],
    ) -> _CachedMethodWrapper[S, P, R]:
        return _CachedMethodWrapper(self, f)

    @property
    def _active_cache(self) -> BaseCache:
        """Per-call cache resolved from the wrapped method's `self`."""
        return self._current_cache.get()

    async def get_from_cache(self, key: str) -> object:
        try:
            return await self._active_cache.get(key)
        except (GlideError, TimeoutError, ValidationError):
            self._log.exception("Couldn't retrieve %s, unexpected error", key)
        return None

    async def set_in_cache(self, key: str, value: object) -> None:
        try:
            await self._active_cache.set(key, value, ttl=self.ttl)
        except (GlideError, TimeoutError, ValidationError):
            self._log.exception("Couldn't set %s, unexpected error", key)


class CacheSerializer(Protocol):
    """Required protocol that is expected by a serializer.

    Compatible with `aiocache.serializer.BaseSerializer`

    This is done to:
    - Force proper type annotations
    - Ensure bytes-direct seralizations are typed properly
    """

    encoding: Optional[str]

    def dumps(self, value: object) -> str | bytes: ...
    def loads(self, value: bytes) -> object: ...


class PydanticSerializer(CacheSerializer):
    """Bytes-direct JSON serializer for a single pydantic model.

    Args:
        model (type[BaseModel]): `BaseModel` to perform searlization on
    """

    encoding: Optional[str] = None

    def __init__(self, model: type[BaseModel]) -> None:
        self._dump = model.__pydantic_serializer__.to_json
        self._validate = model.model_validate_json

    def dumps(self, value: object) -> bytes:
        return self._dump(value)

    def loads(self, value: Optional[bytes]) -> Optional[BaseModel]:
        return None if value is None else self._validate(value)


class ORJSONSerializer(CacheSerializer):
    """Generic bytes-direct JSON serializer utilizing `orjson`

    Note that although derivied from `CacheSerializer`, it follows the same protocol as `BaseSerializer`
    """

    encoding: Optional[str] = None

    def dumps(self, value: object) -> bytes:
        return orjson.dumps(value)

    def loads(self, value: Optional[bytes]) -> object:
        return None if value is None else orjson.loads(value)


# Adapted from: https://github.com/aio-libs/aiocache/blob/master/aiocache/backends/valkey.py
class ValkeyCache(BaseCache):
    """Modified implementation derivied from aiocache's `aiocache.base.BaseCache` utilizing Valkey

    Defaults to the following components:
        - Serializer: `aiocache.serializers.JsonSerializer`
        - Plugins: []

    Args:
        client (GlideClient): Active Valkey GLIDE client
        serializer (Optional[CacheSerializer], optional): Object derivied from `aiocache.serializers.BaseSerializer` or protocols derived from `CacheSerializer`. Defaults to None.
        plugins (Optional[list[BasePlugin]], optional): list of `aiocache.plugins.BasePlugin` derived classes. Defaults to None.
        namespace (Optional[str], optional):string to use as default prefix for the key used in all operations of the backend. Defaults to None.
        key_builder (Optional[Callable[[str, Optional[str]], str]], optional): String or function to utilize for building keys. Defaults to None.
        timeout (Optional[TTLValue], optional): `int` or `float` in seconds specifying maximum timeout for the operations to last. Defaults to 5.
        ttl (Optional[TTLValue], optional): `int` or `float` in seconds specifying the max TTL that an entry is allowed to exist for. Defaults to None.
    """

    NAME = "valkey"

    def __init__(
        self,
        client: GlideClient,
        *,
        serializer: Optional[CacheSerializer] = None,
        plugins: Optional[list[BasePlugin]] = None,
        namespace: Optional[str] = None,
        key_builder: Optional[Callable[[str, Optional[str]], str]] = None,
        timeout: Optional[TTLValue] = 5,
        ttl: Optional[TTLValue] = None,
    ) -> None:
        super().__init__(
            serializer=serializer or JsonSerializer(),
            plugins=plugins,
            namespace=namespace,
            key_builder=key_builder
            or (lambda key, namespace=None: f"{namespace}:{key}" if namespace else key),
            timeout=timeout,
            ttl=ttl,
        )

        self.client = client

    async def _get(
        self,
        key: str,
        encoding: Optional[str] = "utf-8",
        _conn: object = None,
    ) -> Optional[ValkeyValue]:
        value = await self.client.get(key)
        if encoding is None or value is None:
            return value
        return value.decode(encoding) if isinstance(value, bytes) else value

    _gets = _get

    async def _multi_get(
        self,
        keys: list[str],
        encoding: Optional[str] = "utf-8",
        _conn: object = None,
    ) -> list[Optional[ValkeyValue]]:
        values = await self.client.mget(cast("list[ValkeyValue]", keys))
        if encoding is None:
            return list(values)
        return [v.decode(encoding) if isinstance(v, bytes) else v for v in values]

    async def _set(
        self,
        key: str,
        value: ValkeyValue,
        ttl: Optional[TTLValue | ExpirySet] = None,
        _cas_token: object = None,
        _conn: object = None,
    ) -> bool:
        expiry: Optional[ExpirySet] = None
        if isinstance(ttl, ExpirySet):
            expiry = ttl
        elif isinstance(ttl, float):
            expiry = ExpirySet(ExpiryType.MILLSEC, int(ttl * 1000))
        elif ttl:
            expiry = ExpirySet(ExpiryType.SEC, ttl)

        if _cas_token is not None:
            return await self._cas(key, value, _cas_token, ttl=expiry, _conn=_conn)

        return await self.client.set(key, value, expiry=expiry) == "OK"

    async def _cas(
        self,
        key: str,
        value: ValkeyValue,
        token: object,
        ttl: Optional[ExpirySet] = None,
        _conn: object = None,
    ) -> bool:
        if await self._get(key) == token:
            return await self.client.set(key, value, expiry=ttl) == "OK"
        return False

    async def _multi_set(
        self,
        pairs: Iterable[tuple[str, ValkeyValue]],
        ttl: Optional[TTLValue] = None,
        _conn: object = None,
    ) -> bool:
        values: dict[str, ValkeyValue] = dict(pairs)

        if ttl:
            await self.__multi_set_ttl(values, ttl)
        else:
            await self.client.mset(cast("dict[ValkeyValue, ValkeyValue]", values))

        return True

    async def __multi_set_ttl(
        self, values: dict[str, ValkeyValue], ttl: TTLValue
    ) -> None:
        transaction = Batch(is_atomic=True)
        transaction.mset(cast("dict[ValkeyValue, ValkeyValue]", values))
        scaled_ttl, exp = (
            (int(ttl * 1000), transaction.pexpire)
            if isinstance(ttl, float)
            else (ttl, transaction.expire)
        )
        for key in values:
            exp(key, scaled_ttl)
        await self.client.exec(transaction, raise_on_error=True)

    async def _add(
        self,
        key: str,
        value: ValkeyValue,
        ttl: Optional[TTLValue] = None,
        _conn: object = None,
    ) -> bool:
        kwargs: dict[str, Any] = {
            "conditional_set": ConditionalChange.ONLY_IF_DOES_NOT_EXIST
        }
        if isinstance(ttl, float):
            kwargs["expiry"] = ExpirySet(ExpiryType.MILLSEC, int(ttl * 1000))
        elif ttl:
            kwargs["expiry"] = ExpirySet(ExpiryType.SEC, ttl)
        was_set = await self.client.set(key, value, **kwargs)
        if was_set != "OK":
            msg = f"Key {key} already exists, use .set to update the value"
            raise ValueError(msg)
        return True

    async def _exists(self, key: str, _conn: object = None) -> bool:
        return bool(await self.client.exists([key]))

    async def _increment(self, key: str, delta: int, _conn: object = None) -> int:
        try:
            return await self.client.incrby(key, delta)
        except IncrbyException:
            msg = "Value is not an integer"
            raise TypeError(msg) from None

    async def _expire(self, key: str, ttl: int, _conn: object = None) -> bool:
        if ttl == 0:
            return await self.client.persist(key)
        return await self.client.expire(key, ttl)

    async def _delete(self, key: str, _conn: object = None) -> int:
        return await self.client.delete([key])

    async def _clear(
        self, namespace: Optional[str] = None, _conn: object = None
    ) -> bool:
        if not namespace:
            return await self.client.flushdb() == "OK"

        _, keys = await self.client.scan(b"0", f"{namespace}:*")
        if keys and isinstance(keys, list):
            return bool(await self.client.delete(list(keys)))

        return True

    async def _raw(
        self,
        command: str,
        *args: object,
        encoding: Optional[str] = "utf-8",
        _conn: object = None,
        **kwargs: object,
    ) -> object:
        value = await getattr(self.client, command)(*args, **kwargs)
        if encoding is not None and command == "get" and value is not None:
            value = value.decode(encoding)
        return value

    async def _redlock_release(self, key: str, value: ValkeyValue) -> int:
        if await self._get(key) == value:
            return await self.client.delete([key])
        return 0

    def build_key(self, key: str, namespace: Optional[str] = None) -> str:
        """Build the key utilize by the cache

        Args:
            key (str): Key to use
            namespace (Optional[str], optional): Provided namespace for organizing cache keys. Defaults to None.

        Returns:
            str: Complete cache key
        """
        return self._build_key(key, namespace)

    @classmethod
    def parse_uri_path(cls, path: str) -> dict[str, str]:
        """Given a uri path, return the Valkey specific configuration options in that path string according to iana definition

        See: http://www.iana.org/assignments/uri-schemes/prov/redis

        Args:
            path (str): Provided string which contains the path to use. Example: `"/0"`

        Returns:
            dict[str, str]: Mapping contains the options. Example: `{"db": "0"}`
        """
        options: dict[str, str] = {}
        db, *_ = path[1:].split("/")
        if db:
            options["db"] = db
        return options

    def __repr__(self) -> str:
        return (
            f"ValkeyCache ({self.client.config.addresses[0].host}"
            f":{self.client.config.addresses[0].port})"
        )
