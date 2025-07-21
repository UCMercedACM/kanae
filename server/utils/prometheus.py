from __future__ import annotations

import asyncio
import os
import re
import time
from http import HTTPStatus
from typing import (
    TYPE_CHECKING,
    Any,
    Awaitable,
    Callable,
    Optional,
    Sequence,
    Tuple,
    Union,
    cast,
)

from fastapi.requests import Request
from fastapi.responses import Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    REGISTRY,
    CollectorRegistry,
    Gauge,
    generate_latest,
    multiprocess,
)
from prometheus_fastapi_instrumentator import metrics, routing
from starlette.datastructures import Headers

if TYPE_CHECKING:
    from core import Kanae
    from starlette.types import Message, Receive, Scope, Send


class PrometheusMiddleware:
    def __init__(
        self,
        app: Kanae,
        *,
        should_group_status_codes: bool = True,
        should_ignore_not_templated: bool = False,
        should_group_not_templated: bool = True,
        should_round_latency_decimals: bool = False,
        should_respect_env_var: bool = False,
        should_instrument_requests_in_progress: bool = False,
        should_exclude_streaming_duration: bool = False,
        excluded_handlers: Sequence[Union[re.Pattern[str], str]] = (),
        body_handlers: Sequence[Union[re.Pattern[str], str]] = (),
        round_latency_decimals: int = 4,
        in_progress_name: str = "http_requests_in_progress",
        in_progress_labels: bool = False,
        instrumentations: Sequence[Callable[[metrics.Info], None]] = (),
        async_instrumentations: Sequence[
            Callable[[metrics.Info], Awaitable[None]]
        ] = (),
        metric_namespace: str = "",
        metric_subsystem: str = "",
        should_only_respect_2xx_for_higher: bool = False,
        latency_higher_buckets: Sequence[Union[float, str]] = (
            0.01,
            0.025,
            0.05,
            0.075,
            0.1,
            0.25,
            0.5,
            0.75,
            1,
            1.5,
            2,
            2.5,
            3,
            3.5,
            4,
            4.5,
            5,
            7.5,
            10,
            30,
            60,
        ),
        latency_lower_buckets: Sequence[Union[float, str]] = (0.1, 0.5, 1),
        registry: CollectorRegistry = REGISTRY,
        custom_labels: dict = {},
    ) -> None:
        self.app = app

        self.should_group_status_codes = should_group_status_codes
        self.should_ignore_not_templated = should_ignore_not_templated
        self.should_group_not_templated = should_group_not_templated
        self.should_round_latency_decimals = should_round_latency_decimals
        self.should_respect_env_var = should_respect_env_var
        self.should_instrument_requests_in_progress = (
            should_instrument_requests_in_progress
        )

        self.round_latency_decimals = round_latency_decimals
        self.in_progress_name = in_progress_name
        self.in_progress_labels = in_progress_labels
        self.registry = registry
        self.custom_labels = custom_labels

        self.excluded_handlers = [re.compile(path) for path in excluded_handlers]
        self.body_handlers = [re.compile(path) for path in body_handlers]

        if instrumentations:
            self.instrumentations = instrumentations
        else:
            default_instrumentation = metrics.default(
                metric_namespace=metric_namespace,
                metric_subsystem=metric_subsystem,
                should_only_respect_2xx_for_highr=should_only_respect_2xx_for_higher,
                should_exclude_streaming_duration=should_exclude_streaming_duration,
                latency_highr_buckets=latency_higher_buckets,
                latency_lowr_buckets=latency_lower_buckets,
                registry=self.registry,
                custom_labels=custom_labels,
            )
            if default_instrumentation:
                self.instrumentations = [default_instrumentation]
            else:
                self.instrumentations = []

        self.async_instrumentations = async_instrumentations

        self.in_progress: Optional[Gauge] = None
        if self.should_instrument_requests_in_progress:
            labels = (
                (
                    "method",
                    "handler",
                )
                if self.in_progress_labels
                else ()
            )
            self.in_progress = Gauge(
                name=self.in_progress_name,
                documentation="Number of HTTP requests in progress.",
                labelnames=labels,
                multiprocess_mode="livesum",
            )

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        request = Request(scope)
        start_time = time.perf_counter()

        handler, is_templated = self._get_handler(request)
        is_excluded = self._is_handler_excluded(handler, is_templated)
        handler = (
            "none" if not is_templated and self.should_group_not_templated else handler
        )

        if not is_excluded and self.in_progress:
            if self.in_progress_labels:
                in_progress = self.in_progress.labels(request.method, handler)
            else:
                in_progress = self.in_progress
            in_progress.inc()

        status_code = 500
        headers = []
        body = b""
        response_start_time = None

        # Message body collected for handlers matching body_handlers patterns.
        if any(pattern.search(handler) for pattern in self.body_handlers):

            async def send_wrapper(message: Message) -> None:
                if message["type"] == "http.response.start":
                    nonlocal status_code, headers, response_start_time
                    headers = message["headers"]
                    status_code = message["status"]
                    response_start_time = time.perf_counter()
                elif message["type"] == "http.response.body" and message["body"]:
                    nonlocal body
                    body += message["body"]
                await send(message)

        else:

            async def send_wrapper(message: Message) -> None:
                if message["type"] == "http.response.start":
                    nonlocal status_code, headers, response_start_time
                    headers = message["headers"]
                    status_code = message["status"]
                    response_start_time = time.perf_counter()
                await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        except Exception as exc:
            raise exc
        finally:
            status = (
                str(status_code.value)
                if isinstance(status_code, HTTPStatus)
                else str(status_code)
            )

            if not is_excluded:
                duration = max(time.perf_counter() - start_time, 0.0)
                duration_without_streaming = 0.0

                if response_start_time:
                    duration_without_streaming = max(
                        response_start_time - start_time, 0.0
                    )

                if self.should_instrument_requests_in_progress:
                    in_progress.dec()  # type: ignore

                if self.should_round_latency_decimals:
                    duration = round(duration, self.round_latency_decimals)
                    duration_without_streaming = round(
                        duration_without_streaming, self.round_latency_decimals
                    )

                if self.should_group_status_codes:
                    status = status[0] + "xx"

                response = Response(
                    content=body, headers=Headers(raw=headers), status_code=status_code
                )

                info = metrics.Info(
                    request=request,
                    response=response,
                    method=request.method,
                    modified_handler=handler,
                    modified_status=status,
                    modified_duration=duration,
                    modified_duration_without_streaming=duration_without_streaming,
                )

                for instrumentation in self.instrumentations:
                    instrumentation(info)

                await asyncio.gather(
                    *[
                        instrumentation(info)
                        for instrumentation in self.async_instrumentations
                    ]
                )

    def _get_handler(self, request: Request) -> Tuple[str, bool]:
        """Extracts either template or (if no template) path.

        Args:
            request (Request): Python Requests request object.

        Returns:
            Tuple[str, bool]: Tuple with two elements. First element is either
                template or if no template the path. Second element tells you
                if the path is templated or not.
        """
        route_name = routing.get_route_name(request)
        return route_name or request.url.path, True if route_name else False

    def _is_handler_excluded(self, handler: str, is_templated: bool) -> bool:
        """Determines if the handler should be ignored.

        Args:
            handler (str): Handler that handles the request.
            is_templated (bool): Shows if the request is templated.

        Returns:
            bool: `True` if excluded, `False` if not.
        """

        if not is_templated and self.should_ignore_not_templated:
            return True

        if any(pattern.search(handler) for pattern in self.excluded_handlers):
            return True

        return False


class PrometheusInstrumentator:
    def __init__(
        self,
        app: Kanae,
        *,
        should_group_status_codes: bool = True,
        should_ignore_not_templated: bool = False,
        should_group_not_templated: bool = True,
        should_round_latency_decimals: bool = False,
        should_instrument_requests_in_progress: bool = False,
        should_exclude_streaming_duration: bool = False,
        excluded_handlers: list[str] = [],
        body_handlers: list[str] = [],
        round_latency_decimals: int = 4,
        in_progress_name: str = "http_requests_in_progress",
        in_progress_labels: bool = False,
        metric_namespace: str = "",
        metric_subsystem: str = "",
        registry: Union[CollectorRegistry, None] = None,
    ) -> None:
        self.app = app

        self.should_group_status_codes = should_group_status_codes
        self.should_ignore_not_templated = should_ignore_not_templated
        self.should_group_not_templated = should_group_not_templated
        self.should_round_latency_decimals = should_round_latency_decimals
        self.should_instrument_requests_in_progress = (
            should_instrument_requests_in_progress
        )
        self.should_exclude_streaming_duration = should_exclude_streaming_duration

        self.round_latency_decimals = round_latency_decimals
        self.in_progress_name = in_progress_name
        self.in_progress_labels = in_progress_labels
        self.metric_namespace = metric_namespace
        self.metric_subsystem = metric_subsystem

        self.excluded_handlers = [re.compile(path) for path in excluded_handlers]
        self.body_handlers = [re.compile(path) for path in body_handlers]

        self.instrumentations: list[Callable[[metrics.Info], None]] = []
        self.async_instrumentations: list[
            Callable[[metrics.Info], Awaitable[None]]
        ] = []

        self.registry = registry if registry else REGISTRY

    def add_middleware(
        self,
        should_only_respect_2xx_for_higher: bool = False,
        latency_higher_buckets: Sequence[Union[float, str]] = (
            0.01,
            0.025,
            0.05,
            0.075,
            0.1,
            0.25,
            0.5,
            0.75,
            1,
            1.5,
            2,
            2.5,
            3,
            3.5,
            4,
            4.5,
            5,
            7.5,
            10,
            30,
            60,
        ),
        latency_lower_buckets: Sequence[Union[float, str]] = (0.1, 0.5, 1),
    ) -> None:
        self.app.add_middleware(
            PrometheusMiddleware,  # type: ignore (This is actually correct)
            should_group_status_codes=self.should_group_status_codes,
            should_ignore_not_templated=self.should_ignore_not_templated,
            should_group_not_templated=self.should_group_not_templated,
            should_round_latency_decimals=self.should_round_latency_decimals,
            should_instrument_requests_in_progress=self.should_instrument_requests_in_progress,
            should_exclude_streaming_duration=self.should_exclude_streaming_duration,
            round_latency_decimals=self.round_latency_decimals,
            in_progress_name=self.in_progress_name,
            in_progress_labels=self.in_progress_labels,
            instrumentations=self.instrumentations,
            async_instrumentations=self.async_instrumentations,
            excluded_handlers=self.excluded_handlers,
            body_handlers=self.body_handlers,
            metric_namespace=self.metric_namespace,
            metric_subsystem=self.metric_subsystem,
            should_only_respect_2xx_for_higher=should_only_respect_2xx_for_higher,
            latency_higher_buckets=latency_higher_buckets,
            latency_lower_buckets=latency_lower_buckets,
            registry=self.registry,
        )

    def add(
        self,
        *instrumentation_function: Optional[
            Callable[[metrics.Info], Union[None, Awaitable[None]]]
        ],
    ) -> None:
        """Adds function to list of instrumentations.

        Args:
            instrumentation_function: Function
                that will be executed during every request handler call (if
                not excluded). See above for detailed information on the
                interface of the function.

        Returns:
            self: Instrumentator. Builder Pattern.
        """

        for func in instrumentation_function:
            if func:
                if asyncio.iscoroutinefunction(func):
                    self.async_instrumentations.append(
                        cast(
                            Callable[[metrics.Info], Awaitable[None]],
                            func,
                        )
                    )
                else:
                    self.instrumentations.append(
                        cast(Callable[[metrics.Info], None], func)
                    )

    def start(
        self,
        endpoint: str = "/metrics",
        include_in_schema: bool = False,
        **kwargs: Any,
    ) -> None:
        def metrics(request: Request) -> Response:
            """Endpoint that serves Prometheus metrics."""

            ephemeral_registry = self.registry
            if "PROMETHEUS_MULTIPROC_DIR" in os.environ:
                ephemeral_registry = CollectorRegistry()
                multiprocess.MultiProcessCollector(ephemeral_registry)

            resp = Response(content=generate_latest(ephemeral_registry))
            resp.headers["Content-Type"] = CONTENT_TYPE_LATEST

            return resp

        self.app.add_route(
            path=endpoint, route=metrics, include_in_schema=include_in_schema, **kwargs
        )
