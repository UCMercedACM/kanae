from __future__ import annotations

from typing import Annotated, Optional

from fastapi import Depends, Query
from pydantic import BaseModel
from supertokens_python.recipe.session import SessionContainer
from supertokens_python.recipe.session.framework.fastapi import verify_session
from utils.errors import (
    NotFoundException,
    NotFoundMessage,
)
from utils.request import RouteRequest
from utils.responses import DeleteResponse
from utils.router import KanaeRouter

router = KanaeRouter(tags=["Tags"])


class Tags(BaseModel):
    id: int
    title: str
    description: str


class PartialTags(BaseModel):
    title: str


@router.get("/tags")
async def get_tags(
    request: RouteRequest,
    title: Annotated[Optional[str], Query(min_length=3)] = None,
) -> list[Tags]:
    """Get all tags that can be used or sort for a list of tags"""
    query = """
    SELECT id, title, description
    FROM tags
    ORDER BY title DESC
    """

    if title:
        query = """
        SELECT id, title, description
        FROM tags
        WHERE title % $1
        ORDER BY similarity(title, $1) DESC
        """

    args = (title) if title else ()
    records = await request.app.pool.fetch(query, *args)
    return [Tags(**dict(row)) for row in records]


@router.get(
    "/tags/{id}",
    responses={200: {"model": Tags}, 404: {"model": NotFoundMessage}},
)
async def get_tag_by_id(request: RouteRequest, id: int) -> Tags:
    """Get tag via ID"""
    query = """
    SELECT id, title, description
    FROM tags
    WHERE id = $1;
    """

    rows = await request.app.pool.fetchrow(query, id)
    if not rows:
        raise NotFoundException
    return Tags(**dict(rows))


class ModifiedTag(BaseModel):
    title: str
    description: str


@router.put(
    "/tags/{id}",
    responses={200: {"model": Tags}, 404: {"model": NotFoundMessage}},
)
async def edit_tag(request: RouteRequest, id: int, req: ModifiedTag) -> Tags:
    """Modify specified tag"""
    query = """
    UPDATE tags
    SET
        title = $2,
        description = $3
    WHERE id = $1
    RETURNING *;
    """
    rows = await request.app.pool.fetchrow(query, id, *req.model_dump().values())
    if not rows:
        raise NotFoundException(detail="Resource cannot be updated")
    return Tags(**dict(rows))


@router.delete(
    "/tags/{id}",
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundMessage}},
)
async def delete_tag(
    request: RouteRequest,
    id: int,
    session: SessionContainer = Depends(verify_session),
) -> DeleteResponse:
    """Remove specified tag"""
    query = """
    DELETE FROM tags
    WHERE id = $1;
    """

    query_status = await request.app.pool.execute(query, id)
    if query_status[-1] == "0":
        raise NotFoundException
    return DeleteResponse()


@router.post("/tags/create", responses={200: {"model": Tags}})
async def create_tags(
    request: RouteRequest,
    req: ModifiedTag,
    session: SessionContainer = Depends(verify_session),
) -> Tags:
    """Create tag"""
    query = """
    INSERT INTO tags (title, description)
    VALUES ($1, $2)
    RETURNING *;
    """
    rows = await request.app.pool.fetchrow(query, *req.model_dump().values())
    return Tags(**dict(rows))


@router.post("/tags/bulk-create", responses={200: {"model": list[Tags]}})
async def bulk_create_tags(
    request: RouteRequest,
    req: list[ModifiedTag],
    session: SessionContainer = Depends(verify_session),
) -> list[Tags]:
    """Bulk-create tags"""
    query = """
    INSERT INTO tags (title, description)
    VALUES ($1, $2)
    RETURNING *;
    """
    records = await request.app.pool.fetchmany(
        query, [(tag.title, tag.description) for tag in req]
    )
    return [Tags(**dict(tag)) for tag in records]
