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
        """Returns the instance of our app, which is `Kanae`

        Returns:
            Kanae: Application instance
        """
        return self.scope["app"]
