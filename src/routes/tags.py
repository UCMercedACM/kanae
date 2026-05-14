from typing import Annotated, Optional

from fastapi import Query
from pydantic import BaseModel

from utils.checks import Role, has_role
from utils.errors import (
    NotFoundError,
)
from utils.request import RouteRequest
from utils.responses import DeleteResponse, NotFoundResponse
from utils.router import KanaeRouter

router = KanaeRouter(tags=["Tags"])


class Tags(BaseModel, frozen=True):
    id: int
    title: str
    description: str


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

    args = title or ()
    records = await request.app.pool.fetch(query, *args)
    return [Tags(**dict(row)) for row in records]


@router.get(
    "/tags/{tag_id}",
    responses={200: {"model": Tags}, 404: {"model": NotFoundResponse}},
)
async def get_tag_by_id(request: RouteRequest, tag_id: int) -> Tags:
    """Get tag via ID"""
    query = """
    SELECT id, title, description
    FROM tags
    WHERE id = $1;
    """

    rows = await request.app.pool.fetchrow(query, tag_id)
    if not rows:
        raise NotFoundError
    return Tags(**dict(rows))


class ModifiedTag(BaseModel):
    title: str
    description: str


@router.put(
    "/tags/{tag_id}",
    dependencies=[has_role(Role.ADMIN)],
    responses={200: {"model": Tags}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("5/minute")
async def edit_tag(
    request: RouteRequest,
    tag_id: int,
    req: ModifiedTag,
) -> Tags:
    """Modify specified tag"""
    query = """
    UPDATE tags
    SET
        title = $2,
        description = $3
    WHERE id = $1
    RETURNING *;
    """
    rows = await request.app.pool.fetchrow(query, tag_id, *req.model_dump().values())
    if not rows:
        raise NotFoundError(detail="Resource cannot be updated")
    return Tags(**dict(rows))


@router.delete(
    "/tags/{tag_id}",
    dependencies=[has_role(Role.ADMIN)],
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("5/minute")
async def delete_tag(
    request: RouteRequest,
    tag_id: int,
) -> DeleteResponse:
    """Remove specified tag"""
    query = """
    DELETE FROM tags
    WHERE id = $1;
    """

    query_status = await request.app.pool.execute(query, tag_id)
    if query_status[-1] == "0":
        raise NotFoundError
    return DeleteResponse()


@router.post(
    "/tags/create",
    dependencies=[has_role(Role.ADMIN)],
    responses={200: {"model": Tags}},
)
@router.limiter.limit("5/minute")
async def create_tags(
    request: RouteRequest,
    req: ModifiedTag,
) -> Tags:
    """Create tag"""
    query = """
    INSERT INTO tags (title, description)
    VALUES ($1, $2)
    RETURNING *;
    """
    rows = await request.app.pool.fetchrow(query, *req.model_dump().values())
    return Tags(**dict(rows))


@router.post(
    "/tags/bulk-create",
    dependencies=[has_role(Role.ADMIN)],
    responses={200: {"model": list[Tags]}},
)
@router.limiter.limit("1/minute")
async def bulk_create_tags(
    request: RouteRequest,
    req: list[ModifiedTag],
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
