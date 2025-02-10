from pydantic import BaseModel


class DeleteResponse(BaseModel):
    message: str = "ok"


class JoinResponse(BaseModel):
    message: str = "Successfully joined"


class VerifyFailedResponse(BaseModel):
    message: str = "Failed to verify, entirely invalid hash"
