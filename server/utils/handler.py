from __future__ import annotations

from typing import TYPE_CHECKING, Optional

if TYPE_CHECKING:
    import asyncio
    import socket

    from utils.uvicorn.server import KanaeUvicornServer


class InterruptHandler:
    def __init__(
        self, server: KanaeUvicornServer, sockets: Optional[list[socket.socket]] = None
    ) -> None:
        self.server = server
        self.sockets = sockets
        self._task: Optional[asyncio.Task] = None

    def __call__(self) -> None:
        if self._task:
            raise KeyboardInterrupt

        self._task = self.server.loop.create_task(
            self.server.shutdown(sockets=self.sockets)
        )
