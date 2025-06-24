from __future__ import annotations

from typing import TYPE_CHECKING

from fastapi import Request

if TYPE_CHECKING:
    from core import Kanae


class RouteRequest(Request):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

    @property
    def app(self) -> Kanae:
        return self.scope["app"]
