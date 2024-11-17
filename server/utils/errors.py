from pydantic import BaseModel
from fastapi import HTTPException

HTTP_404_DETAIL = "Resource not found"


class NotFoundMessage(BaseModel, frozen=True):
    message: str = HTTP_404_DETAIL


class NotFoundException(HTTPException):
    def __init__(self):
        self.status_code = 404
        self.detail = HTTP_404_DETAIL