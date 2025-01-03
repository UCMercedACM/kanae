from __future__ import annotations

from typing import TYPE_CHECKING, Any, Union
from urllib.parse import parse_qsl

from supertokens_python.framework.request import BaseRequest

if TYPE_CHECKING:
    from fastapi import Request
    from session import PydanticSessionContainer


class FastApiRequest(BaseRequest):
    def __init__(self, request: Request):
        super().__init__()
        self.request = request

    def get_original_url(self) -> str:
        return self.request.url.components.geturl()

    def get_query_param(
        self, key: str, default: Union[str, None] = None
    ) -> Union[str, None]:
        return self.request.query_params.get(key, default)

    def get_query_params(self) -> dict[str, Any]:
        return dict(self.request.query_params.items())

    async def json(self) -> Union[Any, None]:
        try:
            return await self.request.json()
        except Exception:
            return {}

    def method(self) -> str:
        return self.request.method

    def get_cookie(self, key: str) -> Union[str, None]:
        # Note: Unlike other frameworks, FastAPI wraps the value in quotes in Set-Cookie header
        # It also takes care of escaping the quotes while fetching the value
        return self.request.cookies.get(key)

    def get_header(self, key: str) -> Union[str, None]:
        return self.request.headers.get(key, None)

    def get_session(self) -> Union[PydanticSessionContainer, None]:
        return self.request.state.supertokens

    def set_session(self, session: PydanticSessionContainer):
        self.request.state.supertokens = session

    def set_session_as_none(self):
        self.request.state.supertokens = None

    def get_path(self) -> str:
        root_path = self.request.scope.get("root_path")
        if root_path is None:
            raise Exception("should never happen")

        url = self.request.url.path
        # FastAPI seems buggy and it adds an extra root_path (if it matches):
        # So we trim the extra root_path (from the left) from the url
        return url[url.startswith(root_path) and len(root_path) :]

    async def form_data(self):
        return dict(parse_qsl((await self.request.body()).decode("utf-8")))
