from typing import Optional

from errors import HTTP_404_DETAIL
from pydantic import BaseModel


### Failure responses
class FailureResponse(BaseModel, frozen=True):
    result: str = "error"
    detail: str


### Responses for HTTP 400-499 status codes


# HTTP 400
class BadRequestResponse(FailureResponse, frozen=True):
    pass


# HTTP 401
class UnauthorizedResponse(FailureResponse, frozen=True):
    pass


# HTTP 403
class ForbiddenResponse(FailureResponse, frozen=True):
    pass


# HTTP 404
class NotFoundResponse(FailureResponse, frozen=True):
    detail = HTTP_404_DETAIL


# HTTP 409


class ConflictResponse(FailureResponse, frozen=True):
    pass


# Any status codes
class HTTPExceptionResponse(FailureResponse, frozen=True):
    pass


# HTTP 400/422
class RequestValidationErrorDetails(BaseModel, frozen=True):
    detail: str
    context: Optional[str]


class RequestValidationErrorMessage(BaseModel, frozen=True):
    result: str = "error"
    errors: list[RequestValidationErrorDetails]


### Success responses
class SuccessResponse(BaseModel, frozen=True):
    message: str


### General success messages
class DeleteResponse(SuccessResponse, frozen=True):
    message: str = "ok"


class JoinResponse(SuccessResponse, frozen=True):
    message: str = "Successfully joined"
