import functools
import inspect
import itertools
import logging
import sys
import time
from email.utils import formatdate
from functools import wraps
from typing import (
    Any,
    Callable,
    Iterator,
    Literal,
    Optional,
    Union,
)

from dateutil.parser import parse
from fastapi.exceptions import HTTPException
from fastapi.requests import Request
from fastapi.responses import ORJSONResponse, Response
from limits import RateLimitItem, parse_many
from limits.aio.storage import MemoryStorage, RedisStorage
from limits.aio.strategies import FixedWindowRateLimiter, RateLimiter
from limits.errors import StorageError
from pydantic import BaseModel
from starlette.datastructures import MutableHeaders
from utils.config import KanaeConfig

if sys.version_info >= (3, 11):
    from typing import Self
else:
    from typing_extensions import Self

# Define an alias for the most commonly used type
StrOrCallableStr = Union[str, Callable[..., str]]


### Exceptions and handler


async def rate_limit_exceeded_handler(
    request: Request, exc: "RateLimitExceeded"
) -> Response:
    """Builds a JSON response that includes the details of the rate limit that was hit.

    Args:
        request (Request): Instance of `Request`
        exc (RateLimitExceeded): Instance of the exception `RateLimitExceeded`

    Returns:
        Response: A generic JSON response that includes rate limit headers
    """
    response = ORJSONResponse(
        {"error": f"Rate limit exceeded: {exc.detail}"}, status_code=429
    )
    injected_response = await request.app.state.limiter._inject_headers(
        response, request.state.view_rate_limit
    )
    return injected_response


class RateLimitExceeded(HTTPException):
    """Exception for when an rate limit has been hit

    Args:
        limit (LimitItem): Instance of `LimitItem`
    """

    limit = None

    def __init__(self, limit: "LimitItem"):
        self.limit = limit
        self.description = str(limit.limit)

        if limit.error_message:
            self.description: str = (
                limit.error_message
                if not callable(limit.error_message)
                else limit.error_message()
            )

        super(RateLimitExceeded, self).__init__(
            status_code=429, detail=self.description
        )


### Limit configuration models


class InMemorySettings(BaseModel, frozen=True):
    enabled: bool
    limits: list[str]


class LimiterSettings(BaseModel, frozen=True):
    enabled: bool
    headers_enabled: bool
    auto_check: bool
    swallow_errors: bool
    retry_after: Optional[Literal["http-date", "delta-seconds"]]
    default_limits: list[str]
    application_limits: list[str]
    in_memory_fallback: InMemorySettings
    key_prefix: str
    key_style: Literal["endpoint", "url"] = "url"
    storage_uri: str


### Limit Wrappers


class LimitItem:
    """Wrapper around limits and their context"""

    def __init__(
        self,
        limit: RateLimitItem,
        key_func: Callable[..., str],
        *,
        scope: Optional[Union[str, Callable[..., str]]] = None,
        per_method: bool = False,
        methods: Optional[list[str]] = None,
        error_message: Optional[Union[str, Callable[..., str]]] = None,
        exempt_when: Optional[Callable[..., bool]] = None,
        cost: Union[int, Callable[..., int]] = 1,
        override_defaults: bool = False,
    ) -> None:
        self.limit = limit
        self.key_func = key_func
        self.__scope = scope
        self.per_method = per_method
        self.methods = methods
        self.error_message = error_message
        self.exempt_when = exempt_when
        self._exempt_when_takes_request = (
            self.exempt_when
            and len(inspect.signature(self.exempt_when).parameters) == 1
        )
        self.cost = cost
        self.override_defaults = override_defaults

    @property
    def scope(self) -> str:
        """Obtains the scope of the limit

        Returns:
            str: Requested scope
        """
        # flack.request.endpoint is the name of the function for the endpoint
        if self.__scope is None:
            return ""
        return (
            self.__scope(request.endpoint)  # type: ignore # noqa: F821 (this has to be rewritten, dont want to break)
            if callable(self.__scope)
            else self.__scope
        )

    def is_exempt(self, request: Optional[Request] = None) -> bool:
        """Checks whether the limit is exempt or not

        Args:
            request (Optional[Request], optional): Instance of `Request`. Defaults to None.

        Returns:
            bool: True to exempt the route from the limit, False to include
        """
        if not self.exempt_when:
            return False
        elif self._exempt_when_takes_request and request:
            return self.exempt_when(request)
        return self.exempt_when()


class LimitGroup:
    """Represents a group of related limits that returns one limit"""

    def __init__(
        self,
        limit_provider: Union[str, Callable[..., str]],
        key_function: Callable[..., str],
        *,
        scope: Optional[Union[str, Callable[..., str]]] = None,
        per_method: bool = False,
        methods: Optional[list[str]] = None,
        error_message: Optional[Union[str, Callable[..., str]]] = None,
        exempt_when: Optional[Callable[..., bool]] = None,
        cost: Union[int, Callable[..., int]] = 1,
        override_defaults: bool = False,
    ):
        self.__limit_provider = limit_provider
        self.__scope = scope
        self.key_function = key_function
        self.per_method = per_method
        self.methods = methods and [m.lower() for m in methods] or methods
        self.error_message = error_message
        self.exempt_when = exempt_when
        self.cost = cost
        self.override_defaults = override_defaults
        self.request = None

    def __iter__(self) -> Iterator[LimitItem]:
        if callable(self.__limit_provider):
            if (
                "key" in inspect.signature(self.__limit_provider).parameters.keys()
                and "request"
                not in inspect.signature(self.key_function).parameters.keys()
            ):
                raise ValueError(
                    f"Limit provider function {self.key_function.__name__} needs a `request` argument"
                )

            if not self.request:
                raise ValueError("`request` object can't be None")

            limit_raw = self.__limit_provider(self.key_function(self.request))

        else:
            limit_raw = self.__limit_provider

        limit_items: list[RateLimitItem] = parse_many(limit_raw)
        for limit in limit_items:
            yield LimitItem(
                limit,
                self.key_function,
                scope=self.__scope,
                per_method=self.per_method,
                methods=self.methods,
                error_message=self.error_message,
                exempt_when=self.exempt_when,
                cost=self.cost,
                override_defaults=self.override_defaults,
            )

    def with_request(self, request: Request) -> Self:
        """Binds the given request to the group

        Args:
            request (Request): Instance of `Request`

        Returns:
            Self: Group object for builder pattern
        """
        self.request = request
        return self


### Enums


class HEADERS:
    RESET = 1
    REMAINING = 2
    LIMIT = 3
    RETRY_AFTER = 4


MAX_BACKEND_CHECKS = 5


class KanaeLimiter:
    """Modified rate limiter based on SlowAPI's implementation

    Args:
        key_func (Callable[..., str]): Function used to determine the domain of the key
        config (KanaeConfig): Instance of `KanaeConfig`
        enabled (bool, optional): Whether to enable or disable the rate limiter. Defaults to True.
        headers_enabled (bool, optional): Whether to inject `X-RateLimit` and related entries into the header. Defaults to False.
        key_style (Literal["endpoint", "url"], optional): Determines the style of the key to use. `url` uses the path of the request, `endpoint` uses the function module and name. Defaults to `url`.
    """

    _limiter: FixedWindowRateLimiter

    def __init__(
        self,
        key_func: Callable[..., str],
        *,
        config: KanaeConfig,
        enabled: bool = True,
        headers_enabled: bool = False,
        key_style: Literal["endpoint", "url"] = "url",
    ):
        self.logger = logging.getLogger("kanae.limiter")

        _kanae_config = config.kanae.model_dump()
        self._config = LimiterSettings(**_kanae_config["limiter"])

        ### Configuration attributes

        self.enabled = enabled
        self._headers_enabled = headers_enabled or self._config.headers_enabled
        self._auto_check = self._config.auto_check
        self._swallow_errors = self._config.swallow_errors
        self._retry_after = self._config.retry_after
        self._key_prefix = self._config.key_prefix
        self._storage_uri = self._config.storage_uri

        self._key_func = key_func
        self._key_style = key_style

        ### Primary limiter

        self._storage = RedisStorage(
            uri=self._storage_uri,
            implementation="valkey",
            decode_responses=True,
            protocol=3,
        )
        self._limiter = FixedWindowRateLimiter(self._storage)

        ### Memory fallback-related

        self._in_memory_fallback_enabled = (
            self._config.in_memory_fallback.enabled
            or len(self._config.in_memory_fallback.limits) > 0
        )
        self._fallback_limiter: Optional[FixedWindowRateLimiter] = None

        if self._in_memory_fallback_enabled:
            self._fallback_limiter = FixedWindowRateLimiter(storage=MemoryStorage())

        ### Internal flags

        self._storage_dead = False
        self._check_backend_count = 0
        self._last_check_backend = time.monotonic()

        self._header_mapping: dict[int, str] = {
            HEADERS.RESET: "X-RateLimit-Reset",
            HEADERS.REMAINING: "X-RateLimit-Remaining",
            HEADERS.LIMIT: "X-RateLimit-Limit",
            HEADERS.RETRY_AFTER: "Retry-After",
        }

        ### Internal data structures

        self._default_limits = [
            LimitGroup(limit, self._key_func)
            for limit in set(self._config.default_limits)
        ]
        self._application_limits = [
            LimitGroup(limit, self._key_func, scope="global")
            for limit in self._config.application_limits
        ]
        self._in_memory_fallback = [
            LimitGroup(limit, self._key_func)
            for limit in self._config.in_memory_fallback.limits
        ]

        self._exempt_routes: set[str] = set()
        self._request_filters: list[Callable[..., bool]] = []
        self._route_limits: dict[str, list[LimitItem]] = {}
        self._dynamic_route_limits: dict[str, list[LimitGroup]] = {}
        self._marked_for_limiting: dict[str, list[Callable]] = {}

    ### Properties and public methods

    @property
    def limiter(self) -> RateLimiter:
        """Provides the backend that keeps track of consumption of endpoints vs limits

        Raises:
            RuntimeError: If a fallback limiter is `None`

        Returns:
            RateLimiter: Instance of `RateLimiter`. More accurately, `FixedWindowRateLimiter`
        """
        if self._storage_dead and self._in_memory_fallback_enabled:
            if not self._fallback_limiter:
                raise RuntimeError("Fallback limiter cannot be None")
            return self._fallback_limiter
        else:
            return self._limiter

    ### Internal utilities

    async def _reset(self) -> None:
        try:
            await self._storage.reset()
            self.logger.info("Storage has been reset and all limits cleared")
        except NotImplementedError:
            self.logger.warning("This storage type does not support being reset")

    def _should_check_backend(self) -> bool:
        self._check_backend_count = (
            0
            if self._check_backend_count > MAX_BACKEND_CHECKS
            else self._check_backend_count
        )

        if time.monotonic() - self._last_check_backend > pow(
            2, self._check_backend_count
        ):
            self._last_check_backend = time.monotonic()
            self._check_backend_count += 1
            return True
        return False

    def _determine_retry_time(self, retry_header_value: str) -> int:
        if self._retry_after == "http-date":
            retry_after_date = parse(retry_header_value)
            return int(time.mktime(retry_after_date.timetuple()))

        return int(time.monotonic() + int(retry_header_value))

    ## Limit emulations

    async def _evaluate_limits(
        self, request: Request, endpoint: str, limits: list[LimitItem]
    ) -> None:
        failed_limit = None
        limit_for_header = None
        for lim in limits:
            if (
                lim.is_exempt(request)
                or lim.methods is not None
                and request.method.lower() not in lim.methods
            ):
                continue

            limit_scope = lim.scope or endpoint
            limit_key = (
                lim.key_func(request)
                if "request" in inspect.signature(lim.key_func).parameters.keys()
                else lim.key_func()
            )

            if lim.per_method:
                limit_scope += f":{request.method}"

            args = [limit_key, limit_scope]
            if all(args):
                if self._key_prefix:
                    args.insert(0, self._key_prefix)

                if not limit_for_header or lim.limit < limit_for_header[0]:
                    limit_for_header = (lim.limit, args)

                cost = lim.cost(request) if callable(lim.cost) else lim.cost

                # Redis can't decode this if it's not cast into an int for some reason
                if not await self.limiter.hit(lim.limit, *args, cost=int(cost)):
                    self.logger.warning(
                        "ratelimit %s (%s) exceeded at endpoint: %s",
                        lim.limit,
                        limit_key,
                        limit_scope,
                    )
                    failed_limit = lim
                    limit_for_header = (lim.limit, args)
                    break
            else:
                self.logger.error(
                    "Skipping limit: %s. Empty value found in parameters.", lim.limit
                )
        # keep track of which limit was hit, to be picked up for the response header
        request.state.view_rate_limit = limit_for_header

        if failed_limit:
            raise RateLimitExceeded(failed_limit)

    async def _check_request_limit(
        self,
        request: Request,
        endpoint_func: Optional[Callable[..., Any]],
        in_middleware: bool = True,
    ) -> None:
        endpoint_url = request["path"] or ""
        view_func = endpoint_func

        endpoint_func_name = (
            f"{view_func.__module__}.{view_func.__name__}" if view_func else ""
        )
        _endpoint_key = endpoint_url if self._key_style == "url" else endpoint_func_name
        # cases where we don't need to check the limits
        if (
            not _endpoint_key
            or not self.enabled
            # or we are sending a static file
            # or view_func == current_app.send_static_file
            or endpoint_func_name in self._exempt_routes
            or any(fn() for fn in self._request_filters)
        ):
            return
        limits: list[LimitItem] = []
        dynamic_limits: list[LimitItem] = []

        if not in_middleware:
            limits = (
                self._route_limits[endpoint_func_name]
                if endpoint_func_name in self._route_limits
                else []
            )
            dynamic_limits = []
            if endpoint_func_name in self._dynamic_route_limits:
                for lim in self._dynamic_route_limits[endpoint_func_name]:
                    try:
                        dynamic_limits.extend(list(lim.with_request(request)))
                    except ValueError as exc:
                        self.logger.exception(
                            "failed to load ratelimit for view function %s",
                            endpoint_func_name,
                            exc_info=exc,
                        )

        try:
            all_limits: list[LimitItem] = []

            if (
                self._storage_dead
                and self._fallback_limiter
                and not (
                    in_middleware and endpoint_func_name in self._marked_for_limiting
                )
            ):
                if self._should_check_backend() and await self._storage.check():
                    self.logger.info("Rate limit storage recovered")
                    self._storage_dead = False
                    self._check_backend_count = 0
                else:
                    all_limits = list(itertools.chain(*self._in_memory_fallback))

            if not all_limits:
                route_limits: list[LimitItem] = limits + dynamic_limits
                all_limits = (
                    list(itertools.chain(*self._application_limits))
                    if in_middleware
                    else []
                )
                all_limits += route_limits
                combined_defaults = all(
                    not limit.override_defaults for limit in route_limits
                )
                if (
                    not route_limits
                    and not (
                        in_middleware
                        and endpoint_func_name in self._marked_for_limiting
                    )
                    or combined_defaults
                ):
                    all_limits += list(itertools.chain(*self._default_limits))
            # actually check the limits, so far we've only computed the list of limits to check
            await self._evaluate_limits(request, _endpoint_key, all_limits)
        except Exception as e:
            if isinstance(e, RateLimitExceeded):
                raise

            if self._in_memory_fallback_enabled and not self._storage_dead:
                self.logger.warning(
                    "Rate limit storage unreachable - falling back to in-memory storage"
                )
                self._storage_dead = True
                await self._check_request_limit(request, endpoint_func, in_middleware)

            elif self._swallow_errors:
                self.logger.exception("Failed to rate limit. Swallowing error")

    ### Header injection

    async def _inject_headers(
        self, response: Response, current_limit: tuple[RateLimitItem, list[str]]
    ) -> Response:
        if self.enabled and self._headers_enabled and current_limit is not None:
            try:
                window_stats = await self.limiter.get_window_stats(
                    current_limit[0], *current_limit[1]
                )
                reset_in = int(1 + window_stats.reset_time)
                response.headers.append(
                    self._header_mapping[HEADERS.LIMIT], str(current_limit[0].amount)
                )
                response.headers.append(
                    self._header_mapping[HEADERS.REMAINING], str(window_stats.remaining)
                )
                response.headers.append(
                    self._header_mapping[HEADERS.RESET], str(reset_in)
                )

                # response may have an existing retry after
                existing_retry_after_header = response.headers.get("Retry-After")

                if existing_retry_after_header:
                    reset_in = max(
                        self._determine_retry_time(existing_retry_after_header),
                        reset_in,
                    )

                response.headers[self._header_mapping[HEADERS.RETRY_AFTER]] = (
                    formatdate(reset_in, usegmt=True)
                    if self._retry_after == "http-date"
                    else str(int(reset_in - time.monotonic()))
                )
            except StorageError:
                if self._in_memory_fallback and not self._storage_dead:
                    self.logger.warning(
                        "Rate limit storage unreachable - falling back to"
                        " in-memory storage"
                    )
                    self._storage_dead = True
                    response = await self._inject_headers(response, current_limit)
                elif self._swallow_errors:
                    self.logger.error(
                        "Failed to update rate limit headers. Swallowing error"
                    )

        return response

    async def _inject_asgi_headers(
        self, headers: MutableHeaders, current_limit: tuple[RateLimitItem, list[str]]
    ) -> MutableHeaders:
        if self.enabled and self._headers_enabled and current_limit is not None:
            try:
                window_stats = await self.limiter.get_window_stats(
                    current_limit[0], *current_limit[1]
                )
                reset_in = int(1 + window_stats.reset_time)
                headers[self._header_mapping[HEADERS.LIMIT]] = str(
                    current_limit[0].amount
                )
                headers[self._header_mapping[HEADERS.REMAINING]] = str(
                    window_stats.remaining
                )
                headers[self._header_mapping[HEADERS.RESET]] = str(reset_in)

                # response may have an existing retry after
                existing_retry_after_header = headers.get("Retry-After")

                if existing_retry_after_header is not None:
                    reset_in = max(
                        self._determine_retry_time(existing_retry_after_header),
                        reset_in,
                    )

                headers[self._header_mapping[HEADERS.RETRY_AFTER]] = (
                    formatdate(reset_in, usegmt=True)
                    if self._retry_after == "http-date"
                    else str(int(reset_in - time.monotonic()))
                )
            except StorageError:
                if self._in_memory_fallback and not self._storage_dead:
                    self.logger.warning(
                        "Rate limit storage unreachable - falling back to"
                        " in-memory storage"
                    )
                    self._storage_dead = True
                    headers = await self._inject_asgi_headers(headers, current_limit)
                elif self._swallow_errors:
                    self.logger.error(
                        "Failed to update rate limit headers. Swallowing error"
                    )
        return headers

    ### Decorators

    def _limit_decorator(
        self,
        limit_value: StrOrCallableStr,
        key_func: Optional[Callable[..., str]] = None,
        shared: bool = False,
        scope: Optional[StrOrCallableStr] = None,
        per_method: bool = False,
        methods: Optional[list[str]] = None,
        error_message: Optional[str] = None,
        exempt_when: Optional[Callable[..., bool]] = None,
        cost: Union[int, Callable[..., int]] = 1,
        override_defaults: bool = True,
    ) -> Callable[..., Any]:
        _scope = scope if shared else None

        def decorator(func: Callable[..., Response]):
            limit_key_func = key_func or self._key_func
            name = f"{func.__module__}.{func.__name__}"
            dynamic_limit = None
            static_limits: list[LimitItem] = []
            if callable(limit_value):
                dynamic_limit = LimitGroup(
                    limit_value,
                    limit_key_func,
                    scope=_scope,
                    per_method=per_method,
                    methods=methods,
                    error_message=error_message,
                    exempt_when=exempt_when,
                    cost=cost,
                    override_defaults=override_defaults,
                )
            else:
                try:
                    static_limits = list(
                        LimitGroup(
                            limit_value,
                            limit_key_func,
                            scope=_scope,
                            per_method=per_method,
                            methods=methods,
                            error_message=error_message,
                            exempt_when=exempt_when,
                            cost=cost,
                            override_defaults=override_defaults,
                        )
                    )
                except ValueError as exc:
                    self.logger.exception(
                        "Failed to configure throttling for %s", name, exc_info=exc
                    )
            self._marked_for_limiting.setdefault(name, []).append(func)
            if dynamic_limit:
                self._dynamic_route_limits.setdefault(name, []).append(dynamic_limit)
            else:
                self._route_limits.setdefault(name, []).extend(static_limits)

            sig = inspect.signature(func)

            if "request" not in sig.parameters:
                raise ValueError(
                    f"Missing or invalid `request` argument specified on {func}"
                )

            if inspect.iscoroutinefunction(func):
                # Handle async request/response functions.
                @functools.wraps(func)
                async def async_wrapper(*args: Any, **kwargs: Any) -> Response:
                    # get the request object from the decorated endpoint function
                    request = kwargs.get("request")

                    if not isinstance(request, Request):
                        raise ValueError(
                            "parameter `request` must be an instance of fastapi.Request"
                        )

                    if (
                        self.enabled
                        and self._auto_check
                        and not getattr(request.state, "_rate_limiting_complete", False)
                    ):
                        await self._check_request_limit(request, func, False)
                        request.state._rate_limiting_complete = True

                    response = await func(*args, **kwargs)

                    if self._headers_enabled:
                        if not isinstance(response, Response):
                            # get the response object from the decorated endpoint function
                            await self._inject_asgi_headers(
                                kwargs["response"].headers,
                                request.state.view_rate_limit,
                            )
                            return response

                        await self._inject_asgi_headers(
                            response.headers, request.state.view_rate_limit
                        )
                    return response

                return async_wrapper

        return decorator

    def limit(
        self,
        limit_value: StrOrCallableStr,
        key_func: Optional[Callable[..., str]] = None,
        *,
        per_method: bool = False,
        override_defaults: bool = True,
        methods: Optional[list[str]] = None,
        error_message: Optional[str] = None,
        exempt_when: Optional[Callable[..., bool]] = None,
        cost: Union[int, Callable[..., int]] = 1,
    ) -> Callable[..., Any]:
        """A decorator that attaches an limit to the specified individual route

        Args:
            limit_value (Union[str, Callable[..., str]]): String in rate-limit notation or a callable that returns a string in rate-limit notation

                *See https://limits.readthedocs.io/en/stable/quickstart.html#rate-limit-string-notation for details*

            key_func (Optional[Callable[..., str]], optional): Function or lambda that extracts the domain and unique identifier for the rate limit. Defaults to None, which uses the remote address of the request
            per_method (bool, optional): Whether the limit is sub-categorized into the HTTP method of the request. Defaults to False
            override_defaults (bool, optional): Whether to override the default limits. Defaults to True
            methods (Optional[list[str]], optional): If specified, only those HTTP methods in this list will be subjected to rate limits. Defaults to None
            error_message (Optional[str], optional): String that overrides the error message used in the response. Defaults to None
            exempt_when (Optional[Callable[..., bool]], optional): Function that returns an boolean, which indicates whether to exempt the route from the limit. The function can optionally use an `Request` object. Defaults to None
            cost (Union[int, Callable[..., int]], optional): Integer (or callable that returns an integer) which sets the cost of a hit to a backend ratelimiter. Defaults to 1

        Returns:
            Callable[..., Any]: A decorator that injects an limit and returns the original function
        """
        return self._limit_decorator(
            limit_value,
            key_func,
            per_method=per_method,
            methods=methods,
            error_message=error_message,
            exempt_when=exempt_when,
            cost=cost,
            override_defaults=override_defaults,
        )

    def shared_limit(
        self,
        limit_value: StrOrCallableStr,
        key_func: Optional[Callable[..., str]] = None,
        *,
        scope: StrOrCallableStr,
        cost: Union[int, Callable[..., int]] = 1,
        override_defaults: bool = True,
        error_message: Optional[str] = None,
        exempt_when: Optional[Callable[..., bool]] = None,
    ) -> Callable[..., Any]:
        """A decorator that attaches a limit with the same rate limit that is shared amongst multiple routes

        Args:
            limit_value (Union[str, Callable[..., str]]): String in rate-limit notation or a callable that returns a string in rate-limit notation

                *See https://limits.readthedocs.io/en/stable/quickstart.html#rate-limit-string-notation for details*

            key_func (Optional[Callable[..., str]], optional): Function or lambda that extracts the domain and unique identifier for the rate limit. Defaults to None, which uses the remote address of the request
            scope (Union[str, Callable[..., str]], optional): String that defines the scope of the rate limit
            override_defaults (bool, optional): Whether to override the default limits. Defaults to True
            cost (Union[int, Callable[..., int]], optional): Integer (or callable that returns an integer) which sets the cost of a hit to a backend ratelimiter. Defaults to 1
            error_message (Optional[str], optional): String that overrides the error message used in the response. Defaults to None
            exempt_when (Optional[Callable[..., bool]], optional): Function that returns an boolean, which indicates whether to exempt the route from the limit. The function can optionally use an `Request` object. Defaults to None

        Returns:
            Callable[..., Any]: A decorator that injects an shared limit and returns the original function
        """
        return self._limit_decorator(
            limit_value,
            key_func,
            True,
            scope,
            error_message=error_message,
            exempt_when=exempt_when,
            cost=cost,
            override_defaults=override_defaults,
        )

    def exempt(self, func: Callable[..., Any]) -> Callable[..., Any]:
        """A decorator that marks a function as exempt from all rate limits

        Args:
            func (Callable[..., Any]): Provided function to mark as exempt

        Returns:
            Callable[..., Any]: A decorator that injects an exempt clause and returns the original function
        """
        name = "%s.%s" % (func.__module__, func.__name__)

        self._exempt_routes.add(name)

        if inspect.iscoroutinefunction(func):

            @wraps(func)
            async def __async_inner(*a, **k):
                return await func(*a, **k)

            return __async_inner
        else:

            @wraps(func)
            def __inner(*a, **k):
                return func(*a, **k)

            return __inner
