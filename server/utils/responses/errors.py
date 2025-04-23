from typing import Optional

from pydantic import BaseModel

from . import HTTP_404_DETAIL


### Error responses
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


# HTTP 400/422
class RequestValidationErrorDetails(BaseModel, frozen=True):
    detail: str
    context: Optional[str]


class RequestValidationErrorResponse(BaseModel, frozen=True):
    result: str = "error"
    errors: list[RequestValidationErrorDetails]


# Any status codes
class HTTPExceptionResponse(ErrorResponse, frozen=True):
    detail: str
