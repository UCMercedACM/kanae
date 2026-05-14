from collections.abc import Sequence
from typing import Any

import orjson
from fastapi.responses import JSONResponse
from pydantic import BaseModel

HTTP_404_DETAIL = "Resource not found"


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


### Error responses meant for OpenAPI types


# DO NOT use these to raise an HTTP exceptions
class ErrorResponse(BaseModel, frozen=True):
    result: str = "error"
    detail: str


### Responses for HTTP 400-499 status codes


# HTTP 400
class BadRequestResponse(ErrorResponse, frozen=True):
    detail: str


# HTTP 401
class UnauthorizedResponse(ErrorResponse, frozen=True):
    detail: str


# HTTP 403
class ForbiddenResponse(ErrorResponse, frozen=True):
    detail: str


# HTTP 404
class NotFoundResponse(ErrorResponse, frozen=True):
    detail: str = HTTP_404_DETAIL


# HTTP 409
class ConflictResponse(ErrorResponse, frozen=True):
    detail: str


# HTTP 422


class RequestValidationErrorResponse(BaseModel, frozen=True):
    result: str = "error"
    errors: Sequence[Any]


# Any status codes
class HTTPExceptionResponse(ErrorResponse, frozen=True):
    detail: str


### Success responses
class SuccessResponse(BaseModel, frozen=True):
    message: str


### General success messages
class DeleteResponse(SuccessResponse, frozen=True):
    message: str = "ok"


class JoinResponse(SuccessResponse, frozen=True):
    message: str = "Successfully joined"
