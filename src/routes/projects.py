import asyncio
import datetime
import uuid
from typing import Annotated, Literal, Optional, TypedDict

import asyncpg
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from core import (
    ALLOWED_IMAGE_TYPES,
    ALLOWED_VIDEO_TYPES,
    MultipartUploadChunks,
    UploadChunk,
    store_thumbnail,
)
from utils.auth import use_session
from utils.checks import Project, Role, check_any, has_permissions, has_role
from utils.errors import BadGatewayError, BadRequestError, ConflictError, NotFoundError
from utils.ory import KanaeSession
from utils.pages import KanaePages, KanaeParams, paginate
from utils.request import RouteRequest
from utils.responses import (
    BadRequestResponse,
    ConflictResponse,
    DeleteResponse,
    ForbiddenResponse,
    HTTPExceptionResponse,
    JoinResponse,
    NotFoundResponse,
    SuccessResponse,
)
from utils.router import KanaeRouter

router = KanaeRouter(tags=["Projects"])

_SINGLE_PUT_MAX = 16 * 1024 * 1024  # 16 MB — below this, single PUT
_MAX_IMAGE_SIZE = 32 * 1024 * 1024  # 32 MB
_MAX_VIDEO_SIZE = 2 * 1024 * 1024 * 1024  # 2 GB

_HASH_REGEX = r"^[0-9a-f]{64}$"
_NO_NULL_REGEX = r"^[^\x00]+$"


class ProjectThumbnail(BaseModel, frozen=True):
    hash: Annotated[str, Field(pattern=_HASH_REGEX)]
    url: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


class ProjectMember(BaseModel, frozen=True):
    id: uuid.UUID
    name: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


class Projects(BaseModel, frozen=True):
    id: uuid.UUID
    name: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    description: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    link: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    type: Literal[
        "independent",
        "sig_ai",
        "sig_swe",
        "sig_cyber",
        "sig_data",
        "sig_arch",
        "sig_graph",
    ]
    tags: Optional[list[Annotated[str, Field(pattern=_NO_NULL_REGEX)]]] = None
    active: bool
    founded_at: datetime.datetime


class FullProjects(BaseModel, frozen=True):
    id: uuid.UUID
    name: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    description: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    link: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    thumbnail: Optional[ProjectThumbnail] = None
    members: list[ProjectMember]
    type: Literal[
        "independent",
        "sig_ai",
        "sig_swe",
        "sig_cyber",
        "sig_data",
        "sig_arch",
        "sig_graph",
    ]
    tags: Optional[list[Annotated[str, Field(pattern=_NO_NULL_REGEX)]]] = None
    active: bool
    founded_at: datetime.datetime


@router.get("/projects")
async def list_projects(
    request: RouteRequest,
    name: Annotated[Optional[str], Query(min_length=3, pattern=_NO_NULL_REGEX)] = None,
    since: Optional[datetime.datetime] = None,
    until: Optional[datetime.datetime] = None,
    *,
    active: Optional[bool] = True,
    params: Annotated[KanaeParams, Depends()],
) -> KanaePages[FullProjects]:
    """Search and filter a list of projects"""
    if since and until:
        msg = "Cannot specify both parameters. Must be only one be specified."
        raise BadRequestError(msg)

    args: list = [request.app.storage.base_thumbnail_url]
    time_constraint = ""

    if name:
        if since or until:
            if since:
                time_constraint = "AND projects.founded_at >= $3"
                args.append(since)
            elif until:
                time_constraint = "AND projects.founded_at <= $3"
                args.append(until)

        constraint = f"WHERE projects.name % $2 {time_constraint} GROUP BY projects.id ORDER BY similarity(projects.name, $2) DESC"
        args.insert(1, name)
    elif active is not None:
        constraint = "WHERE projects.active = $2 GROUP BY projects.id"
        args.append(active)
    else:
        if since:
            time_constraint = "projects.founded_at >= $2 AND projects.active = $3"
            args.extend((since, active))
        elif until:
            time_constraint = "projects.founded_at <= $2 AND projects.active = $3"
            args.extend((until, active))
        constraint = f"WHERE {time_constraint} GROUP BY projects.id"

    # ruff: noqa: S608
    query = f"""
    SELECT
        projects.id, projects.name, projects.description, projects.link,
        jsonb_agg(jsonb_build_object('id', members.id, 'name', members.name, 'role', project_members.role)) AS members,
        projects.type, projects.active,
        CASE WHEN projects.thumbnail_hash IS NOT NULL THEN
            jsonb_build_object(
                'hash', projects.thumbnail_hash,
                'url', $1 || '/thumbnails/' || projects.thumbnail_hash || '.webp'
            )
        END AS thumbnail,
        projects.founded_at
    FROM projects
    INNER JOIN project_members ON project_members.project_id = projects.id
    INNER JOIN members ON project_members.member_id = members.id
    {constraint}
    """

    return await paginate(request.app.pool, query, *args, params=params)  # ty: ignore[invalid-return-type]


@router.get(
    "/projects/{project_id}",
    responses={200: {"model": FullProjects}, 404: {"model": NotFoundResponse}},
)
async def get_project(request: RouteRequest, project_id: uuid.UUID) -> FullProjects:
    """Retrieve project details via ID"""
    query = """
    SELECT
        projects.id, projects.name, projects.description, projects.link,
        jsonb_agg(jsonb_build_object('id', members.id, 'name', members.name, 'role', project_members.role)) AS members,
        projects.type, projects.active,
        CASE WHEN projects.thumbnail_hash IS NOT NULL THEN
            jsonb_build_object(
                'hash', projects.thumbnail_hash,
                'url', $2 || '/thumbnails/' || projects.thumbnail_hash || '.webp'
            )
        END AS thumbnail,
        projects.founded_at
    FROM projects
    INNER JOIN project_members ON project_members.project_id = projects.id
    INNER JOIN members ON project_members.member_id = members.id
    WHERE projects.id = $1
    GROUP BY projects.id;
    """
    rows = await request.app.pool.fetchrow(
        query, project_id, request.app.storage.base_thumbnail_url
    )
    if not rows:
        raise NotFoundError
    return FullProjects(**dict(rows))


class ModifiedProject(BaseModel, frozen=True):
    name: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    description: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    link: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


@router.put(
    "/projects/{project_id}",
    dependencies=[has_permissions(Project.edit)],
    responses={200: {"model": Projects}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("3/minute")
async def edit_project(
    request: RouteRequest,
    project_id: uuid.UUID,
    req: ModifiedProject,
) -> Projects:
    """Updates the specified project"""
    query = """
    UPDATE projects
    SET
        name = $2,
        description = $3,
        link = $4
    WHERE id = $1
    RETURNING *;
    """
    rows = await request.app.pool.fetchrow(
        query, project_id, *req.model_dump().values()
    )

    if not rows:
        raise NotFoundError(detail="Resource cannot be updated")
    return Projects(**dict(rows))


@router.delete(
    "/projects/{project_id}",
    dependencies=[has_permissions(Project.own)],
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("3/minute")
async def delete_project(
    request: RouteRequest,
    project_id: uuid.UUID,
) -> DeleteResponse:
    """Deletes the specified project"""
    query = """
    DELETE FROM projects
    WHERE id = $1
    RETURNING thumbnail_hash
    """
    status = await request.app.pool.fetchrow(query, project_id)
    if status is None:
        raise NotFoundError

    if status["thumbnail_hash"]:
        await request.app.storage.delete_thumbnail(status["thumbnail_hash"])

    return DeleteResponse()


class CreateProject(BaseModel, frozen=True):
    name: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    description: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    link: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    type: Literal[
        "independent",
        "sig_ai",
        "sig_swe",
        "sig_cyber",
        "sig_data",
        "sig_arch",
        "sig_graph",
    ]
    tags: Optional[list[Annotated[str, Field(pattern=_NO_NULL_REGEX)]]] = None
    active: bool
    founded_at: datetime.datetime


@router.post(
    "/projects/create",
    dependencies=[has_role(Role.MANAGER)],
    responses={200: {"model": Projects}, 422: {"model": HTTPExceptionResponse}},
)
@router.limiter.limit("5/minute")
async def create_project(
    request: RouteRequest,
    req: CreateProject,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> Projects:
    """Creates a new project given the provided data"""
    query = """
    WITH new_project AS (
        INSERT INTO projects (name, description, link, type, active, founded_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING *
    ), new_member AS (
        INSERT INTO project_members (project_id, member_id, role)
        SELECT id, $7, 'lead' FROM new_project
    )
    SELECT * FROM new_project;
    """

    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()

        project_rows = await connection.fetchrow(
            query,
            *req.model_dump(exclude={"tags"}).values(),
            session.identity.id,
        )

        if req.tags:
            subquery = """
            INSERT INTO project_tags (project_id, tag_id)
            VALUES ($1, (SELECT id FROM tags WHERE title = $2));
            """

            await tr.start()

            try:
                await request.app.pool.fetchmany(
                    subquery, [(project_rows["id"], tags.lower()) for tags in req.tags]
                )
            except asyncpg.NotNullViolationError:
                await tr.rollback()

                # Remove the newly created entry, somewhat like a rollback
                await connection.execute(
                    "DELETE FROM projects WHERE id = $1;", project_rows["id"]
                )
                raise HTTPException(
                    detail="The tag(s) specified is invalid. Please check the current tags available.",
                    status_code=422,
                )
            else:
                await tr.commit()

        return Projects(**dict(project_rows), tags=req.tags)


@router.post(
    "/projects/{project_id}/join",
    responses={200: {"model": JoinResponse}, 409: {"model": ConflictResponse}},
)
@router.limiter.limit("5/minute")
async def join_project(
    request: RouteRequest,
    project_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> JoinResponse:
    # The member is authenticated already, aka meaning that there is an existing member in our database
    query = """
    INSERT INTO project_members (project_id, member_id, role)
    VALUES ($1, $2, 'member');
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()
        try:
            await connection.execute(query, project_id, session.identity.id)
        except asyncpg.UniqueViolationError:
            await tr.rollback()
            msg = "Authenticated member has already joined the requested project"
            raise ConflictError(msg)
        except asyncpg.ForeignKeyViolationError:
            await tr.rollback()
            msg = "Project or member does not exist"
            raise NotFoundError(msg)
        else:
            await tr.commit()
            return JoinResponse(message="ok")


class BulkJoinMember(BaseModel, frozen=True):
    id: uuid.UUID


@router.post(
    "/projects/{project_id}/bulk-join",
    dependencies=[
        check_any(has_role(Role.MANAGER), has_permissions(Project.own)),
    ],
    responses={
        200: {"model": JoinResponse},
        409: {"model": ConflictResponse},
    },
)
@router.limiter.limit("1/minute")
async def bulk_join_project(
    request: RouteRequest,
    project_id: uuid.UUID,
    req: list[BulkJoinMember],
) -> JoinResponse:
    if len(req) > 10:
        msg = "Must be less than 10 members"
        raise BadRequestError(msg)

    # The member is authenticated already, aka meaning that there is an existing member in our database
    query = """
    INSERT INTO project_members (project_id, member_id, role)
    VALUES ($1, $2, 'member');
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()
        try:
            await connection.executemany(
                query, [(project_id, entry.id) for entry in req]
            )
        except asyncpg.UniqueViolationError:
            await tr.rollback()
            msg = "Authenticated member has already joined the requested project"
            raise ConflictError(msg)
        except asyncpg.ForeignKeyViolationError:
            await tr.rollback()
            msg = "Project or one of the supplied members does not exist"
            raise NotFoundError(msg)
        else:
            await tr.commit()
            return JoinResponse(message="ok")


@router.delete(
    "/projects/{project_id}/leave",
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("5/minute")
async def leave_project(
    request: RouteRequest,
    project_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> DeleteResponse:
    query = """
    DELETE FROM project_members
    WHERE project_id = $1 AND member_id = $2;
    """
    async with request.app.pool.acquire() as connection:
        status = await connection.execute(query, project_id, session.identity.id)
        if status[-1] == "0":
            raise NotFoundError

        return DeleteResponse()


class UpgradeMemberRole(BaseModel, frozen=True):
    id: uuid.UUID
    role: Literal["former", "lead"]


@router.put(
    "/projects/{project_id}/member/modify",
    dependencies=[has_permissions(Project.own), has_role(Role.MANAGER)],
    include_in_schema=False,
    responses={200: {"model": DeleteResponse}},
)
@router.limiter.limit("3/minute")
async def modify_member(
    request: RouteRequest,
    project_id: uuid.UUID,
    req: UpgradeMemberRole,
) -> DeleteResponse:
    """Undocumented route to just upgrade/demote member role in projects"""
    query = """
    UPDATE project_members
        SET role = $3
    WHERE project_id = $1 AND member_id = $2;
    """
    await request.app.pool.execute(query, project_id, req.id, req.role)
    return DeleteResponse()


def _validate_media(content_type: str, size: int) -> None:
    """Raise if `(content_type, size)` isn't a permissible media upload.

    Resolves the kind from the content-type allow-list (415 on miss), then
    enforces the per-kind size cap (400 on non-positive, 413 over the cap).
    No return — the DB derives `kind` from `content_type` via a generated
    column, so callers don't need it.
    """
    if content_type in ALLOWED_IMAGE_TYPES:
        cap, label = _MAX_IMAGE_SIZE, "Image"
    elif content_type in ALLOWED_VIDEO_TYPES:
        cap, label = _MAX_VIDEO_SIZE, "Video"
    else:
        msg = f"Unsupported content type: {content_type}"
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail=msg,
        )

    if size <= 0:
        msg = "Size must be positive"
        raise BadRequestError(msg)

    if size > cap:
        msg = f"{label} size {size} exceeds limit {cap}"
        raise HTTPException(
            status_code=status.HTTP_413_CONTENT_TOO_LARGE,
            detail=msg,
        )


class SimpleUploadResponse(BaseModel, frozen=True):
    url: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


class MultipartUploadResponse(BaseModel, frozen=True):
    upload_id: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    size: int
    chunks: list[UploadChunk]


class MediaRecord(BaseModel, frozen=True):
    hash: Annotated[str, Field(pattern=_HASH_REGEX)]
    content_type: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    kind: Literal["image", "video"]
    size: int
    created_at: datetime.datetime
    url: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


class UploadRequest(BaseModel, frozen=True):
    hash: Annotated[str, Field(pattern=_HASH_REGEX)]
    content_type: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    size: int


@router.post(
    "/projects/{project_id}/media/upload",
    dependencies=[has_permissions(Project.edit)],
    responses={
        400: {"model": BadRequestResponse},
        403: {"model": ForbiddenResponse},
        413: {"model": HTTPExceptionResponse},
        415: {"model": HTTPExceptionResponse},
    },
)
@router.limiter.limit("10/minute")
async def upload_media(
    request: RouteRequest,
    project_id: uuid.UUID,
    req: UploadRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> MediaRecord | SimpleUploadResponse | MultipartUploadResponse:
    """Begin a media upload by minting presigned URL(s) or returning the existing record"""
    _validate_media(req.content_type, req.size)

    query = """
    WITH media_exists AS (
        SELECT hash, content_type, kind, size, created_at
        FROM media
        WHERE hash = $1
    ),
    link AS (
        INSERT INTO project_media (project_id, media_hash)
        SELECT $2, hash FROM media_exists
        ON CONFLICT DO NOTHING
    )
    SELECT hash, content_type, kind, size, created_at FROM media_exists;
    """

    exists = await request.app.pool.fetchrow(query, req.hash, project_id)
    if exists:
        url = await request.app.storage.get_url(exists["hash"], exists["content_type"])
        return MediaRecord(**dict(exists), url=url)

    if req.size <= _SINGLE_PUT_MAX:
        url = await request.app.storage.upload(req.hash, content_type=req.content_type)
        return SimpleUploadResponse(url=url)

    multipart = await request.app.storage.init_multipart(
        req.hash, content_type=req.content_type, size=req.size
    )
    return MultipartUploadResponse(
        upload_id=multipart.upload_id,
        size=multipart.chunk_size,
        chunks=multipart.chunks,
    )


class CompletedChunk(TypedDict):
    number: int
    etag: str


class CommitRequest(BaseModel, frozen=True):
    hash: Annotated[str, Field(pattern=_HASH_REGEX)]
    content_type: Annotated[str, Field(pattern=_NO_NULL_REGEX)]
    size: int
    upload_id: Optional[Annotated[str, Field(pattern=_NO_NULL_REGEX)]] = None
    chunks: Optional[list[CompletedChunk]] = None


@router.post(
    "/projects/{project_id}/media/commit",
    dependencies=[has_permissions(Project.edit)],
    responses={
        200: {"model": MediaRecord},
        400: {"model": BadRequestResponse},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
        409: {"model": ConflictResponse},
        413: {"model": HTTPExceptionResponse},
        415: {"model": HTTPExceptionResponse},
        502: {"model": HTTPExceptionResponse},
    },
)
@router.limiter.limit("10/minute")
async def commit_media(
    request: RouteRequest,
    project_id: uuid.UUID,
    req: CommitRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> MediaRecord:
    """Finalize a media upload after the raw data are in storage"""
    _validate_media(req.content_type, req.size)

    if (req.upload_id is None) ^ (req.chunks is None):
        msg = "upload_id and parts must be provided together"
        raise BadRequestError(msg)

    if req.upload_id is not None and req.chunks is not None:
        try:
            await request.app.storage.finish_multipart(
                req.hash,
                upload_id=req.upload_id,
                content_type=req.content_type,
                chunks=[
                    MultipartUploadChunks(
                        chunk_index=chunk["number"], etag=chunk["etag"]
                    )
                    for chunk in req.chunks
                ],
            )

        except (BotoCoreError, ClientError):
            await request.app.storage.cancel_multipart(
                req.upload_id, req.hash, content_type=req.content_type
            )

            msg = "Failed to complete the multipart upload for some reason"
            raise BadGatewayError(msg)

    head = await request.app.storage.head(req.hash, content_type=req.content_type)
    if head["ContentLength"] != req.size:
        await request.app.storage.delete(req.hash, content_type=req.content_type)

        msg = "Uploaded size does not match declared size"
        raise ConflictError(msg)

    query = """
    WITH insert_media AS (
        INSERT INTO media (hash, content_type, size, creator_id)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (hash) DO UPDATE
            SET hash = EXCLUDED.hash
        RETURNING hash, content_type, kind, size, created_at
    ), link AS (
        INSERT INTO project_media (project_id, media_hash)
        SELECT $5, hash FROM insert_media
        ON CONFLICT DO NOTHING
    )
    SELECT hash, content_type, kind, size, created_at FROM insert_media;
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()

        try:
            record = await connection.fetchrow(
                query,
                req.hash,
                req.content_type,
                req.size,
                session.identity.id,
                project_id,
            )
        except asyncpg.ForeignKeyViolationError:
            await tr.rollback()

            msg = "Project or creator no longer exists"
            raise NotFoundError(msg)

        else:
            await tr.commit()

    url = await request.app.storage.get_url(record["hash"], record["content_type"])
    return MediaRecord(
        hash=record["hash"],
        content_type=record["content_type"],
        kind=record["kind"],
        size=record["size"],
        created_at=record["created_at"],
        url=url,
    )


class SetThumbnailRequest(BaseModel, frozen=True):
    hash: Annotated[str, Field(pattern=_HASH_REGEX)]
    content_type: Annotated[str, Field(pattern=_NO_NULL_REGEX)]


@router.post(
    "/projects/{project_id}/thumbnail",
    dependencies=[has_permissions(Project.edit)],
    responses={
        200: {"model": SuccessResponse},
        400: {"model": BadRequestResponse},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
    },
)
@router.limiter.limit("3/minute")
async def set_project_thumbnail(
    request: RouteRequest,
    project_id: uuid.UUID,
    req: SetThumbnailRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> SuccessResponse:
    """Sets the thumbnail used for a given project"""
    processed_image = await store_thumbnail(
        request, media_hash=req.hash, content_type=req.content_type
    )

    # There is a slight but rare race condition if two simultatneous requests can read the pre-updated thumbnail_hash
    # Issue a "FOR UPDATE" row lock to prevent this race from happening
    # Without it, two simultaneous requests can each read the
    # pre-update `thumbnail_hash` against their own snapshot, then one's UPDATE
    # commits and the other's cleanup branch deletes a stale hash — leaving the
    # first writer's WebP object orphaned in the public bucket.
    query = """
        WITH locked AS (
            SELECT thumbnail_hash FROM projects
            WHERE id = $2
            FOR UPDATE
        ), old AS (
            SELECT thumbnail_hash FROM locked
            WHERE thumbnail_hash IS NOT NULL AND thumbnail_hash != $1
        )
        UPDATE projects
        SET thumbnail_hash = $1
        WHERE id = $2
          AND EXISTS (
              SELECT 1 FROM project_media
              WHERE project_id = $2 AND media_hash = $3
          )
        RETURNING id, (SELECT thumbnail_hash FROM old) AS old_hash;
    """
    response = await request.app.pool.fetchrow(
        query,
        processed_image.hash,
        project_id,
        req.hash,
    )

    if response is None:
        await request.app.storage.delete_thumbnail(processed_image.hash)
        msg = "Project not found, or source media is not associated with it"
        raise NotFoundError(msg)

    if response["old_hash"]:
        await request.app.storage.delete_thumbnail(response["old_hash"])

    return SuccessResponse(message="ok")


@router.get(
    "/projects/{project_id}/media",
    dependencies=[has_permissions(Project.view)],
    responses={
        200: {"model": list[MediaRecord]},
        403: {"model": ForbiddenResponse},
    },
)
@router.limiter.limit("60/minute")
async def list_project_media(
    request: RouteRequest,
    project_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> list[MediaRecord]:
    """List all media associated with a project."""
    query = """
    SELECT media.hash, media.content_type, media.kind, media.size, media.created_at
    FROM project_media
    JOIN media ON media.hash = project_media.media_hash
    WHERE project_media.project_id = $1
    ORDER BY project_media.position NULLS LAST, project_media.created_at;
    """

    rows = await request.app.pool.fetch(query, project_id)

    # Normally we would not bother with this, as no results = no iterations
    # But since we are sending getting the URLs in parraell, it makes more sense here
    if not rows:
        return []

    urls = await asyncio.gather(
        *(request.app.storage.get_url(row["hash"], row["content_type"]) for row in rows)
    )

    return [
        MediaRecord(
            hash=row["hash"],
            content_type=row["content_type"],
            kind=row["kind"],
            size=row["size"],
            created_at=row["created_at"],
            url=url,
        )
        for row, url in zip(rows, urls, strict=True)
    ]


class ReorderRequest(BaseModel, frozen=True):
    hashes: list[Annotated[str, Field(pattern=_HASH_REGEX)]]


@router.put(
    "/projects/{project_id}/media/positions",
    dependencies=[has_permissions(Project.edit)],
    responses={
        200: {"model": SuccessResponse},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
    },
)
@router.limiter.limit("5/minute")
async def reorder_project_media(
    request: RouteRequest,
    project_id: uuid.UUID,
    req: ReorderRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> SuccessResponse:
    """Reorders the positions of the order on how media will be displayed within a project"""
    query = """
    WITH desired AS (
        SELECT hash, ord
        FROM unnest($2::text[]) WITH ORDINALITY AS d(hash, ord)
    ), updated AS (
        UPDATE project_media pm
        SET position = desired.ord - 1
        FROM desired
        WHERE pm.project_id = $1
          AND pm.media_hash = desired.hash
        RETURNING 1
    )
    SELECT COUNT(*) FROM updated
    """

    res = await request.app.pool.fetchval(query, project_id, req.hashes)

    if res != len(req.hashes):
        msg = "One or more hashes do not belong to the project"
        raise NotFoundError(msg)

    return SuccessResponse(message="okie")


@router.delete(
    "/projects/{project_id}/media/{media_hash}",
    dependencies=[has_permissions(Project.edit)],
    responses={
        200: {"model": DeleteResponse},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
    },
)
@router.limiter.limit("5/minute")
async def remove_project_media(
    request: RouteRequest,
    project_id: uuid.UUID,
    media_hash: Annotated[str, Field(pattern=_HASH_REGEX)],
) -> DeleteResponse:
    """Removes the specified media from the associated project"""
    query = """
    DELETE FROM project_media
    WHERE project_id = $1 AND media_hash = $2;
    """
    orphan_query = """
    DELETE FROM media
    WHERE hash = $1
      AND NOT EXISTS (
          SELECT 1 FROM project_media WHERE media_hash = $1
      )
    RETURNING content_type;
    """
    async with request.app.pool.acquire() as connection:
        initial_delete = await connection.execute(query, project_id, media_hash)

        if initial_delete[-1] == "0":
            raise NotFoundError

        orphan = await connection.fetchrow(orphan_query, media_hash)

        if orphan:
            await request.app.storage.delete(
                media_hash, content_type=orphan["content_type"]
            )
            await request.app.storage.get_url.cache_invalidate(
                media_hash, orphan["content_type"]
            )

        return DeleteResponse()


@router.delete(
    "/projects/{project_id}/thumbnail",
    dependencies=[has_permissions(Project.edit)],
    responses={
        200: {"model": DeleteResponse},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
    },
)
@router.limiter.limit("5/minute")
async def remove_project_thumbnail(
    request: RouteRequest,
    project_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> DeleteResponse:
    """Removes the associated thumbnail of a given project"""
    query = """
    WITH old_thumbnail AS (
        SELECT thumbnail_hash
        FROM projects
        WHERE id = $1
    )
    UPDATE projects
    SET thumbnail_hash = NULL
    WHERE id = $1
    RETURNING id, (SELECT thumbnail_hash FROM old_thumbnail) AS old_hash
    """

    response = await request.app.pool.fetchrow(query, project_id)

    if not response:
        raise NotFoundError

    if response["old_hash"]:
        await request.app.storage.delete_thumbnail(response["old_hash"])

    return DeleteResponse()
