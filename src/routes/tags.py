import uuid
from typing import Annotated, Literal, Optional

from fastapi import Path, Query
from pydantic import BaseModel, Field

from utils.checks import Role, check_any, has_role, has_sudo
from utils.errors import AttachedTagError, NotFoundError
from utils.request import RouteRequest
from utils.responses import DeleteResponse, NotFoundResponse
from utils.router import KanaeRouter

router = KanaeRouter(tags=["Tags"])

# Represents the limits of signed 32-bit int (1 - 2,147,483,647)
# We use INT in our schema, which is 32-bit,
# so safely assume the max is 32-bits
_TAG_ID_MIN: int = 1
_TAG_ID_MAX: int = 2**31 - 1

_NO_NULL_REGEX = r"^[^\x00]+$"


class Tags(BaseModel, frozen=True):
    id: int
    title: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    description: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


class FullTags(BaseModel, frozen=True):
    id: int
    title: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    description: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    in_use: bool


@router.get("/tags")
async def get_tags(
    request: RouteRequest,
    title: Annotated[Optional[str], Query(min_length=3, pattern=_NO_NULL_REGEX)] = None,
) -> list[FullTags]:
    """Get all tags that can be used or sort for a list of tags"""
    query = """
    SELECT id, title, description,
    (EXISTS (SELECT 1 FROM project_tags WHERE tag_id = tags.id)
         OR EXISTS (SELECT 1 FROM event_tags WHERE tag_id = tags.id)) AS in_use
    FROM tags
    ORDER BY title DESC
    """

    if title:
        query = """
        SELECT id, title, description,
        (EXISTS (SELECT 1 FROM project_tags WHERE tag_id = tags.id)
             OR EXISTS (SELECT 1 FROM event_tags WHERE tag_id = tags.id)) AS in_use
        FROM tags
        WHERE title % $1
        ORDER BY similarity(title, $1) DESC
        """

    args: tuple[str, ...] = (title,) if title else ()
    records = await request.app.pool.fetch(query, *args)
    return [FullTags(**dict(row)) for row in records]


@router.get(
    "/tags/{tag_id}",
    responses={200: {"model": FullTags}, 404: {"model": NotFoundResponse}},
)
async def get_tag_by_id(
    request: RouteRequest,
    tag_id: Annotated[int, Path(ge=_TAG_ID_MIN, le=_TAG_ID_MAX)],
) -> FullTags:
    """Get tag via ID"""
    query = """
    SELECT id, title, description,
    (EXISTS (SELECT 1 FROM project_tags WHERE tag_id = tags.id)
         OR EXISTS (SELECT 1 FROM event_tags WHERE tag_id = tags.id)) AS in_use
    FROM tags
    WHERE id = $1;
    """

    rows = await request.app.pool.fetchrow(query, tag_id)
    if not rows:
        raise NotFoundError
    return FullTags(**dict(rows))


class ModifiedTag(BaseModel):
    title: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    description: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


@router.put(
    "/tags/{tag_id}",
    dependencies=[check_any(has_role(Role.ROOT), has_sudo())],
    responses={200: {"model": Tags}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("5/minute")
async def edit_tag(
    request: RouteRequest,
    tag_id: Annotated[int, Path(ge=_TAG_ID_MIN, le=_TAG_ID_MAX)],
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


class AttachedTagEntry(BaseModel, frozen=True):
    id: uuid.UUID
    name: str
    type: Literal["Project", "Event"]


class AttachedTagResponse(BaseModel, frozen=True):
    detail: str
    entries: list[AttachedTagEntry]


@router.delete(
    "/tags/{tag_id}",
    dependencies=[check_any(has_role(Role.ROOT), has_sudo())],
    responses={
        200: {"model": DeleteResponse},
        404: {"model": NotFoundResponse},
        409: {"model": AttachedTagResponse},
    },
)
@router.limiter.limit("5/minute")
async def delete_tag(
    request: RouteRequest,
    tag_id: Annotated[int, Path(ge=_TAG_ID_MIN, le=_TAG_ID_MAX)],
) -> DeleteResponse:
    """Remove specified tag"""
    query = """
    WITH usage AS (
        SELECT projects.id, projects.name, 'Project' as type
        FROM project_tags
        JOIN projects ON projects.id = project_tags.project_id
        WHERE project_tags.tag_id = $1

        UNION ALL

        SELECT events.id, events.name, 'Event' AS type
        FROM event_tags
        JOIN events ON events.id = event_tags.event_id
        WHERE event_tags.tag_id = $1
    ), deleted AS (
        DELETE FROM tags
        WHERE id = $1
          AND NOT EXISTS (SELECT 1 FROM usage)
        RETURNING id
    )
    SELECT
        (SELECT jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'type', u.type))
             FROM usage u) AS entries,
        EXISTS (SELECT 1 FROM usage) AS in_use,
        EXISTS (SELECT 1 FROM deleted) AS deleted;
    """

    row = await request.app.pool.fetchrow(query, tag_id)

    if row["in_use"]:
        entries = [AttachedTagEntry(**entry) for entry in row["entries"]]

        msg = "Tag is still in use"
        raise AttachedTagError(msg, entries=entries)

    if not row["deleted"]:
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
    dependencies=[check_any(has_role(Role.ROOT), has_sudo())],
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
