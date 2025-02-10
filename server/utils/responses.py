from pydantic import BaseModel


class DeleteResponse(BaseModel):
    message: str = "ok"


class JoinResponse(BaseModel):
    message: str = "Successfully joined"
