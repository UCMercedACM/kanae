from fastapi import HTTPException
from pydantic import BaseModel

HTTP_404_DETAIL = "Resource not found"


class NotFoundMessage(BaseModel, frozen=True):
    message: str = HTTP_404_DETAIL


class NotFoundException(HTTPException):
    def __init__(self, detail: str = HTTP_404_DETAIL):
        self.status_code = 404
        self.detail = detail


class BadRequestException(HTTPException):
    def __init__(self, detail: str):
        self.status_code = 40
        self.detail = detail


class RequestValidationErrorDetails(BaseModel, frozen=True):
    detail: str
    context: str


class RequestValidationErrorMessage(BaseModel, frozen=True):
    result: str = "error"
    errors: list[RequestValidationErrorDetails]


class HTTPExceptionMessage(BaseModel, frozen=True):
    result: str = "error"
    detail: str
