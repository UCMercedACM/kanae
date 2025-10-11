# Wrapper around uvicorn.Server to handle uvloop/winloop
import os
import signal
import socket
from typing import Optional

import uvicorn
from utils.handler import InterruptHandler
from utils.uvicorn.config import KanaeUvicornConfig

if os.name == "nt":
    from winloop import new_event_loop, run
else:
    from uvloop import new_event_loop, run


class KanaeUvicornServer(uvicorn.Server):
    def __init__(self, config: KanaeUvicornConfig):
        super().__init__(config)

    def run(self, sockets: Optional[list[socket.socket]] = None) -> None:
        self.loop = new_event_loop()
        handler = InterruptHandler(server=self, sockets=sockets)

        self.loop.add_signal_handler(signal.SIGINT, handler)
        self.loop.add_signal_handler(signal.SIGTERM, handler)
        return run(self.serve(sockets=sockets))
