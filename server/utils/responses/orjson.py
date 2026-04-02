from typing import Any

import orjson
from fastapi.responses import JSONResponse


class ORJSONResponse(JSONResponse):
    """
    Faster response for searlizing plain-dict responeses for error handlers

    Although FastAPI has [deprecated ORJSONResponse](https://github.com/fastapi/fastapi/pull/14964), the performance gains don't affect error handlers. We also need to report status codes properly.

    See https://github.com/fastapi/fastapi/pull/14964#issuecomment-3943248627
    """

    def render(self, content: Any) -> bytes:  # noqa: ANN401
        return orjson.dumps(
            content, option=orjson.OPT_NON_STR_KEYS | orjson.OPT_SERIALIZE_NUMPY
        )
