from __future__ import annotations

from typing import TYPE_CHECKING

from fastapi import Request

if TYPE_CHECKING:
    from starlette.types import Receive, Scope, Send

    from core import Kanae


class RouteRequest(Request):
    def __init__(self, scope: Scope, receive: Receive, send: Send) -> None:
        super().__init__(scope, receive, send)

    @property
    def app(self) -> Kanae:
        """Returns the instance of our app, which is `Kanae`

        Returns:
            Kanae: Application instance
        """
        return self.scope["app"]
