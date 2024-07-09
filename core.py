import asyncio
from typing import Optional

from fastapi import FastAPI
from utils.config import AppConfig
import firebase_admin
from google.cloud import firestore

description = """
This app serves as an base template for internal FastAPI apps
"""


class ServerApp(FastAPI):
    def __init__(
        self,
        *,
        loop: Optional[asyncio.AbstractEventLoop] = None,
        config: AppConfig,
    ):
        self.loop: asyncio.AbstractEventLoop = (
            loop or asyncio.get_event_loop_policy().get_event_loop()
        )
        super().__init__(
            title="Example Template",
            version="0.1.0",
            description=description,
            loop=self.loop,
            redoc_url="/docs",
            docs_url=None,
        )
        self.config = config
        self.add_event_handler("startup", func=self.startup)
        self.add_event_handler("shutdown", func=self.shutdown)

    async def startup(self) -> None:
        self.state.app = firebase_admin.initialize_app()
        self.state.db = firestore.AsyncClient()

    async def shutdown(self) -> None:
        print("stopping")
