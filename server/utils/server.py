# Wrapper around uvicorn.Server to handle uvloop/winloop
import asyncio
import os
import signal
import socket
from typing import Optional

import uvicorn
from utils.config import KanaeUvicornConfig
from utils.handler import InterruptHandler

if os.name == "nt":
    from winloop import new_event_loop, run
else:
    from uvloop import new_event_loop, run


class KanaeUvicornServer(uvicorn.Server):
    def __init__(self, config: KanaeUvicornConfig):
        super().__init__(config)
        self.loop = new_event_loop()

    def _register_signals(self, sockets: Optional[list[socket.socket]] = None) -> None:
        handler = InterruptHandler(server=self, sockets=sockets)
        self.loop.add_signal_handler(signal.SIGINT, handler)
        self.loop.add_signal_handler(signal.SIGTERM, handler)

    def run(self, sockets: Optional[list[socket.socket]] = None) -> None:
        self._register_signals(sockets)
        return run(self.serve(sockets=sockets))

    def multi_run(self, sockets: Optional[list[socket.socket]] = None) -> None:
        return asyncio.run(self.serve(sockets=sockets))
