from fastapi import HTTPException

from .responses import HTTP_404_DETAIL


class BaseHTTPException(HTTPException):
    status_code: int

    def __init__(self, detail: str):
        self.detail = detail


# HTTP 400
class BadRequestException(BaseHTTPException):
    def __init__(self, detail: str):
        super().__init__(detail)
        self.status_code = 400


# HTTP 401
class UnauthorizedException(BaseHTTPException):
    def __init__(self, detail: str):
        super().__init__(detail)
        self.status_code = 401


# HTTP 403
class ForbiddenException(BaseHTTPException):
    def __init__(self, detail: str):
        super().__init__(detail)
        self.status_code = 403


# HTTP 404
class NotFoundException(BaseHTTPException):
    def __init__(self, detail: str = HTTP_404_DETAIL):
        super().__init__(detail)
        self.status_code = 404


# HTTP 409
class ConflictException(BaseHTTPException):
    def __init__(self, detail: str):
        super().__init__(detail)
        self.status_code = 409
