from __future__ import annotations

import asyncio
import socket
from typing import TYPE_CHECKING, Optional

from uvicorn.server import Server

if TYPE_CHECKING:
    from core import Kanae


class InterruptHandler:
    def __init__(
        self, core: Kanae, server: Server, sockets: Optional[list[socket.socket]] = None
    ):
        self.core = core
        self.server = server
        self.sockets = sockets
        self._task: Optional[asyncio.Task] = None

    def __call__(self):
        if self._task:
            raise KeyboardInterrupt

        self._task = self.core.loop.create_task(
            self.server.shutdown(sockets=self.sockets)
        )
