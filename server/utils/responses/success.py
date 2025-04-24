from pydantic import BaseModel


### Success responses
class SuccessResponse(BaseModel, frozen=True):
    message: str


### General success messages
class DeleteResponse(SuccessResponse, frozen=True):
    message: str = "ok"


class JoinResponse(SuccessResponse, frozen=True):
    message: str = "Successfully joined"
