from __future__ import annotations

from typing import TYPE_CHECKING, TypedDict, Unpack

from fastapi import APIRouter

from core import KanaeConfig, find_config
from utils.limiter import KanaeLimiter
from utils.limiter.utils import get_remote_address

if TYPE_CHECKING:
    from collections.abc import Callable, Sequence
    from enum import Enum

    from fastapi.params import Depends
    from fastapi.routing import APIRoute
    from starlette.responses import Response
    from starlette.routing import BaseRoute
    from starlette.types import ASGIApp, Lifespan


class _APIRouterKwargs(TypedDict, total=False):
    prefix: str
    tags: list[str | Enum] | None
    dependencies: Sequence[Depends] | None
    default_response_class: type[Response]
    responses: dict[int | str, dict[str, object]] | None
    callbacks: list[BaseRoute] | None
    routes: list[BaseRoute] | None
    redirect_slashes: bool
    default: ASGIApp | None
    route_class: type[APIRoute]
    on_startup: Sequence[Callable[[], object]] | None
    on_shutdown: Sequence[Callable[[], object]] | None
    lifespan: Lifespan[object] | None
    deprecated: bool | None
    include_in_schema: bool
    generate_unique_id_function: Callable[[APIRoute], str]
    strict_content_type: bool


class KanaeRouter(APIRouter):
    # Shared across every KanaeRouter so that `lifespan`'s single
    # `app.limiter.attach(app.glide)` is observed by every per-module
    # `@router.limiter.limit(...)` decorator. Without this, sub-routers
    # build their own ValkeyStorage whose _manager is never set.
    _shared_limiter: KanaeLimiter | None = None

    def __init__(self, **kwargs: Unpack[_APIRouterKwargs]) -> None:
        super().__init__(**kwargs)

        if KanaeRouter._shared_limiter is None:
            config = KanaeConfig.load_from_file(find_config())
            KanaeRouter._shared_limiter = KanaeLimiter(
                get_remote_address, config=config
            )
        self.limiter: KanaeLimiter = KanaeRouter._shared_limiter
