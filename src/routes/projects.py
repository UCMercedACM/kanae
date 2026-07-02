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
from utils.errors import (
    BadGatewayError,
    BadRequestError,
    ConflictError,
    ForbiddenError,
    NotFoundError,
    ServiceUnavailableError,
)
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

_INVITE_TTL = datetime.timedelta(days=7)

_INVITE_NOT_FOUND = "Invite does not exist"
_PROJECT_OR_MEMBER_NOT_FOUND = "Project or member does not exist"
_EXPIRED_INVITE = "This invite has expired"
_AUTH_PERMS_FAILED = "Failed to verify permissions with the authorization service"

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
    join_policy: Literal["open", "request", "closed"]
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
    join_policy: Literal["open", "request", "closed"]
    founded_at: datetime.datetime


class ProjectInvite(BaseModel, frozen=True):
    id: uuid.UUID
    project_id: uuid.UUID
    member: ProjectMember
    invited_by: Optional[uuid.UUID] = None
    kind: Literal["invite", "request"]
    status: Literal["pending", "accepted", "declined", "revoked", "expired"]
    message: Optional[Annotated[str, Field(pattern=_NO_NULL_REGEX)]] = None
    responded_at: Optional[datetime.datetime] = None
    expires_at: Optional[datetime.datetime] = None
    created_at: datetime.datetime


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
        projects.type, projects.active, projects.join_policy,
        (
            SELECT array_agg(tags.title ORDER BY tags.title)
            FROM project_tags
            JOIN tags ON tags.id = project_tags.tag_id
            WHERE project_tags.project_id = projects.id
        ) AS tags,
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
        projects.type, projects.active, projects.join_policy,
        (
            SELECT array_agg(tags.title ORDER BY tags.title)
            FROM project_tags
            JOIN tags ON tags.id = project_tags.tag_id
            WHERE project_tags.project_id = projects.id
        ) AS tags,
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


class ArchiveProject(BaseModel, frozen=True):
    active: bool


@router.put(
    "/projects/{project_id}/archive",
    dependencies=[has_permissions(Project.own)],
    responses={200: {"model": Projects}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("3/minute")
async def archive_project(
    request: RouteRequest,
    project_id: uuid.UUID,
    req: ArchiveProject,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> Projects:
    """Archives or restores a project by toggling its active flag"""
    query = """
    UPDATE projects
    SET active = $2
    WHERE id = $1
    RETURNING *;
    """
    rows = await request.app.pool.fetchrow(query, project_id, req.active)
    if not rows:
        raise NotFoundError
    return Projects(**dict(rows))


class ProjectTagsResponse(BaseModel, frozen=True):
    tags: list[str]


class ModifyProjectTags(BaseModel, frozen=True):
    tags: list[Annotated[str, Field(pattern=_NO_NULL_REGEX)]]


@router.put(
    "/projects/{project_id}/tags",
    dependencies=[has_permissions(Project.edit)],
    responses={
        200: {"model": ProjectTagsResponse},
        404: {"model": NotFoundResponse},
        422: {"model": HTTPExceptionResponse},
    },
)
@router.limiter.limit("5/minute")
async def edit_project_tags(
    request: RouteRequest,
    project_id: uuid.UUID,
    req: ModifyProjectTags,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> ProjectTagsResponse:
    """Replaces a project's entire tag set with the supplied one. Also allows for partial edits"""
    query = """
    WITH check_project AS (
        SELECT 1 FROM projects
        WHERE id = $1 FOR UPDATE
    ), delete_project_tags AS (
        DELETE FROM project_tags
        WHERE project_id = $1
    )
    SELECT EXISTS (SELECT 1 FROM check_project) AS exists;
    """
    resulting_query = """
    SELECT tags.title
    FROM project_tags
    JOIN tags ON tags.id = project_tags.tag_id
    WHERE project_tags.project_id = $1
    ORDER BY tags.title;
    """

    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()
        try:
            exists = await connection.fetchval(
                query,
                project_id,
            )
            if not exists:
                await tr.rollback()
                raise NotFoundError

            if req.tags:
                subquery = """
                INSERT INTO project_tags (project_id, tag_id)
                VALUES ($1, (SELECT id FROM tags WHERE title = $2))
                ON CONFLICT DO NOTHING;
                """
                await connection.executemany(
                    subquery, [(project_id, tag.lower()) for tag in req.tags]
                )

            resulting_tags = await connection.fetch(
                resulting_query,
                project_id,
            )
        except asyncpg.NotNullViolationError:
            await tr.rollback()
            raise HTTPException(
                detail="The tag(s) specified is invalid. Please check the current tags available.",
                status_code=422,
            )
        else:
            await tr.commit()

        return ProjectTagsResponse(tags=[row["title"] for row in resulting_tags])


@router.delete(
    "/projects/{project_id}/tags",
    dependencies=[has_permissions(Project.edit)],
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundResponse}},
)
@router.limiter.limit("5/minute")
async def clear_project_tags(
    request: RouteRequest,
    project_id: uuid.UUID,
) -> DeleteResponse:
    """Removes all tags from a project"""
    query = """
    WITH check_project AS (
        SELECT 1 FROM projects
        WHERE id = $1
    ), delete_project_tags AS (
        DELETE FROM project_tags
        WHERE project_id = $1
    )
    SELECT EXISTS (SELECT 1 FROM check_project) AS exists;
    """
    exists = await request.app.pool.fetchval(query, project_id)
    if not exists:
        raise NotFoundError
    return DeleteResponse()


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
    responses={
        200: {"model": Projects},
        422: {"model": HTTPExceptionResponse},
        502: {"model": HTTPExceptionResponse},
    },
)
@router.limiter.limit("15/minute")
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
        await tr.start()

        try:
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

                await connection.fetchmany(
                    subquery, [(project_rows["id"], tags.lower()) for tags in req.tags]
                )

            project_id = str(project_rows["id"])
            await request.app.ory.grant(
                "Project", project_id, "owners", subject_id=session.identity.id
            )
            await request.app.ory.grant(
                "Project",
                project_id,
                "editors",
                subject_set={
                    "namespace": "Role",
                    "object": "manager",
                    "relation": "member",
                },
            )
        except asyncpg.NotNullViolationError:
            await tr.rollback()

            raise HTTPException(
                detail="The tag(s) specified is invalid. Please check the current tags available.",
                status_code=422,
            )
        except (BadGatewayError, ServiceUnavailableError):
            await tr.rollback()

            msg = "Failed to record project ownership in the authorization service"
            raise BadGatewayError(msg)
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
    """Joins a given project"""
    # The member is authenticated already, aka meaning that there is an existing member in our database
    query = """
    WITH target AS (
        SELECT id, join_policy FROM projects WHERE id = $1
    ), insert_member AS (
        INSERT INTO project_members (project_id, member_id, role)
        SELECT id, $2, 'member' FROM target WHERE join_policy = 'open'
        RETURNING 1
    )
    SELECT
        (SELECT join_policy FROM target) AS join_policy,
        EXISTS (SELECT 1 FROM insert_member) AS member_joined;
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()
        try:
            row = await connection.fetchrow(query, project_id, session.identity.id)

            if not row["join_policy"]:
                await tr.rollback()

                raise NotFoundError(_PROJECT_OR_MEMBER_NOT_FOUND)

            if not row["member_joined"]:
                await tr.rollback()

                msg = "This project is not open to direct joins or requests."
                raise ConflictError(msg)

        except asyncpg.UniqueViolationError:
            await tr.rollback()
            msg = "Authenticated member has already joined the requested project"
            raise ConflictError(msg)
        except asyncpg.ForeignKeyViolationError:
            await tr.rollback()
            raise NotFoundError(_PROJECT_OR_MEMBER_NOT_FOUND)
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
    """Join projects in bulk. Must be less than 10 members"""
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


class ModifyJoinPolicy(BaseModel, frozen=True):
    join_policy: Literal["open", "request", "closed"]


@router.post(
    "/projects/{project_id}/join-policy",
    dependencies=[check_any(has_role(Role.MANAGER), has_permissions(Project.edit))],
    responses={
        200: {"model": Projects},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
    },
)
@router.limiter.limit("5/minute")
async def set_project_join_policy(
    request: RouteRequest,
    project_id: uuid.UUID,
    req: ModifyJoinPolicy,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> Projects:
    """Sets the given project's join policy"""
    query = """
    UPDATE projects
    SET join_policy = $2
    WHERE id = $1
    RETURNING *;
    """
    rows = await request.app.pool.fetchrow(query, project_id, req.join_policy)

    if not rows:
        raise NotFoundError
    return Projects(**dict(rows))


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
    """Leaves a given project"""
    query = """
    DELETE FROM project_members
    WHERE project_id = $1 AND member_id = $2;
    """
    async with request.app.pool.acquire() as connection:
        status = await connection.execute(query, project_id, session.identity.id)
        if status[-1] == "0":
            raise NotFoundError

        return DeleteResponse()


class CreateInvite(BaseModel, frozen=True):
    member_id: uuid.UUID
    message: Optional[Annotated[str, Field(pattern=_NO_NULL_REGEX, max_length=500)]] = (
        None
    )


@router.post(
    "/projects/{project_id}/invites",
    dependencies=[check_any(has_role(Role.MANAGER), has_permissions(Project.edit))],
    responses={
        200: {"model": ProjectInvite},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
        409: {"model": ConflictResponse},
    },
)
@router.limiter.limit("5/minute")
async def create_invite(
    request: RouteRequest,
    project_id: uuid.UUID,
    req: CreateInvite,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> ProjectInvite:
    """Creates an invite to a given project"""
    query = """
    WITH ctx AS (
        SELECT
            EXISTS (
                SELECT 1 FROM project_members
                WHERE project_id = $1 AND member_id = $2
            ) AS is_member,
            (
                SELECT kind FROM project_invites
                WHERE project_id = $1 AND member_id = $2 AND status = 'pending'
            ) AS pending_kind
    ), new_invite AS (
        INSERT INTO project_invites (project_id, member_id, invited_by, kind, message, expires_at)
        SELECT $1, $2, $3, 'invite', $4, NOW() + $5
        FROM ctx
        WHERE NOT ctx.is_member AND ctx.pending_kind IS NULL
        RETURNING *
    )
    SELECT
        ctx.is_member, ctx.pending_kind,
        new_invite.id, new_invite.project_id,
        jsonb_build_object('id', members.id, 'name', members.name) AS member,
        new_invite.invited_by, new_invite.kind, new_invite.status,
        new_invite.message, new_invite.created_at, new_invite.responded_at,
        new_invite.expires_at
    FROM ctx
    LEFT JOIN new_invite ON TRUE
    LEFT JOIN members ON members.id = $2;
    """
    clear_stale_query = """
    UPDATE project_invites SET status = 'expired'
    WHERE project_id = $1 AND member_id = $2
      AND status = 'pending'
      AND expires_at IS NOT NULL AND expires_at <= NOW();
    """

    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()

        try:
            await connection.execute(clear_stale_query, project_id, req.member_id)
            row = await connection.fetchrow(
                query,
                project_id,
                req.member_id,
                session.identity.id,
                req.message,
                _INVITE_TTL,
            )

            if row["is_member"]:
                await tr.rollback()

                msg = "This member is already part of the project"
                raise ConflictError(msg)

            if row["pending_kind"] is not None:
                await tr.rollback()

                msg = (
                    "This member has already requested to join — accept their request instead"
                    if row["pending_kind"] == "request"
                    else "A pending invite already exists for this member"
                )
                raise ConflictError(msg)
        except asyncpg.UniqueViolationError:
            await tr.rollback()

            msg = "A pending invite already exists for this member"
            raise ConflictError(msg)
        except asyncpg.ForeignKeyViolationError:
            await tr.rollback()

            raise NotFoundError(_PROJECT_OR_MEMBER_NOT_FOUND)
        else:
            await tr.commit()
            return ProjectInvite(**dict(row))


class CreateRequest(BaseModel, frozen=True):
    message: Optional[Annotated[str, Field(pattern=_NO_NULL_REGEX, max_length=500)]] = (
        None
    )


@router.post(
    "/projects/{project_id}/requests",
    responses={
        200: {"model": ProjectInvite},
        404: {"model": NotFoundResponse},
        409: {"model": ConflictResponse},
    },
)
@router.limiter.limit("5/minute")
async def create_request(
    request: RouteRequest,
    project_id: uuid.UUID,
    req: CreateRequest,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> ProjectInvite:
    """Requests to join the project on behalf of the calling member"""
    query = """
    WITH membership AS (
        SELECT EXISTS (
            SELECT 1 FROM project_members
            WHERE project_id = $1 AND member_id = $2
        ) AS is_member
    ), pending AS (
        SELECT kind FROM project_invites
        WHERE project_id = $1 AND member_id = $2 AND status = 'pending'
    ), new_request AS (
        INSERT INTO project_invites (project_id, member_id, invited_by, kind, message, expires_at)
        SELECT $1, $2, $2, 'request', $3, NOW() + $4
        FROM projects
        CROSS JOIN membership
        WHERE projects.id = $1
          AND projects.join_policy = 'request'
          AND NOT membership.is_member
          AND NOT EXISTS (SELECT 1 FROM pending)
        RETURNING *
    )
    SELECT
        projects.join_policy,
        membership.is_member,
        (SELECT kind FROM pending) AS pending_kind,
        new_request.id, new_request.project_id,
        jsonb_build_object('id', members.id, 'name', members.name) AS member,
        new_request.invited_by, new_request.kind, new_request.status,
        new_request.message, new_request.created_at, new_request.responded_at,
        new_request.expires_at
    FROM projects
    CROSS JOIN membership
    LEFT JOIN new_request ON TRUE
    LEFT JOIN members ON members.id = $2
    WHERE projects.id = $1;
    """
    clear_stale_query = """
    UPDATE project_invites SET status = 'expired'
    WHERE project_id = $1 AND member_id = $2
      AND status = 'pending'
      AND expires_at IS NOT NULL AND expires_at <= NOW();
    """

    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()

        try:
            await connection.execute(clear_stale_query, project_id, session.identity.id)
            row = await connection.fetchrow(
                query, project_id, session.identity.id, req.message, _INVITE_TTL
            )

            if not row or row["is_member"] or row["join_policy"] != "request":
                await tr.rollback()

                if not row:
                    msg = "Project does not exist"
                    raise NotFoundError(msg)
                if row["is_member"]:
                    msg = "You are already part of this project"
                    raise ConflictError(msg)
                if row["join_policy"] == "open":
                    msg = "This project is open — use POST /projects/{id}/join"
                    raise ConflictError(msg)

                msg = "This project is not accepting join requests"
                raise ConflictError(msg)

            if row["id"] is None:
                await tr.rollback()

                msg = (
                    "You already have a pending invite to this project — accept it instead"
                    if row["pending_kind"] == "invite"
                    else "You already have a pending request for this project"
                )
                raise ConflictError(msg)

        except asyncpg.UniqueViolationError:
            await tr.rollback()

            msg = "You already have a pending handshake for this project"
            raise ConflictError(msg)
        else:
            await tr.commit()
            return ProjectInvite(**dict(row))


async def _can_respond_to_invite(
    request: RouteRequest,
    *,
    kind: str,
    member_id: uuid.UUID,
    project_id: uuid.UUID,
    subject_id: str,
) -> bool:
    if kind == "invite":
        return str(member_id) == str(subject_id)

    return await request.app.ory.check_permission(
        "Role", Role.MANAGER, "member", subject_id
    ) or await request.app.ory.check_permission(
        "Project", str(project_id).lower(), "edit", subject_id
    )


async def _can_revoke_invite(
    request: RouteRequest,
    *,
    kind: str,
    invited_by: Optional[uuid.UUID],
    project_id: uuid.UUID,
    subject_id: str,
) -> bool:
    if invited_by is not None and str(invited_by) == str(subject_id):
        return True

    if kind == "invite":
        return await request.app.ory.check_permission(
            "Role", Role.MANAGER, "member", subject_id
        ) or await request.app.ory.check_permission(
            "Project", str(project_id).lower(), "edit", subject_id
        )

    return False


class InviteActionResponse(BaseModel, frozen=True):
    id: uuid.UUID
    status: Literal["accepted", "declined", "revoked"]


@router.post(
    "/projects/{project_id}/invites/{invite_id}/accept",
    responses={
        200: {"model": InviteActionResponse},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
        409: {"model": ConflictResponse},
        502: {"model": HTTPExceptionResponse},
    },
)
@router.limiter.limit("5/minute")
async def accept_project_invite(
    request: RouteRequest,
    project_id: uuid.UUID,
    invite_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> InviteActionResponse:
    """Accepts a pending project invite and joins the given project"""
    query = """
    WITH locked AS (
        SELECT member_id, kind, status, expires_at
        FROM project_invites
        WHERE id = $2 AND project_id = $1
        FOR UPDATE
    ), updated AS (
        UPDATE project_invites
        SET status = 'accepted', responded_at = NOW() AT TIME ZONE 'utc'
        WHERE id = $2 AND project_id = $1
          AND status = 'pending'
          AND (expires_at IS NULL OR expires_at > NOW())
        RETURNING id
    ), expired_update AS (
        UPDATE project_invites
        SET status = 'expired'
        WHERE id = $2 AND project_id = $1
          AND status = 'pending'
          AND expires_at IS NOT NULL AND expires_at <= NOW()
    ), membership AS (
        INSERT INTO project_members (project_id, member_id, role)
        SELECT $1, member_id, 'member'
        FROM locked
        WHERE locked.status = 'pending'
          AND (locked.expires_at IS NULL OR locked.expires_at > NOW())
        ON CONFLICT (project_id, member_id) DO NOTHING
    )
    SELECT
        locked.kind, locked.member_id, locked.status,
        (locked.expires_at IS NOT NULL AND locked.expires_at <= NOW()) AS expired,
        updated.id IS NOT NULL AS accepted
    FROM locked
    LEFT JOIN updated ON TRUE;
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()
        try:
            row = await connection.fetchrow(query, project_id, invite_id)

            if not row:
                await tr.rollback()
                raise NotFoundError(_INVITE_NOT_FOUND)

            if row["expired"]:
                await tr.commit()
                raise ConflictError(_EXPIRED_INVITE)

            if not row["accepted"] or not await _can_respond_to_invite(
                request,
                kind=row["kind"],
                member_id=row["member_id"],
                project_id=project_id,
                subject_id=session.identity.id,
            ):
                await tr.rollback()

                if not row["accepted"]:
                    msg = f"This invite is already {row['status']}"
                    raise ConflictError(msg)

                msg = "You cannot respond to this invite"
                raise ForbiddenError(msg)
        except asyncpg.ForeignKeyViolationError:
            await tr.rollback()
            msg = "Project or member no longer exists"
            raise NotFoundError(msg)
        except (BadGatewayError, ServiceUnavailableError):
            await tr.rollback()
            raise BadGatewayError(_AUTH_PERMS_FAILED)
        else:
            await tr.commit()
            return InviteActionResponse(id=invite_id, status="accepted")


@router.post(
    "/projects/{project_id}/invites/{invite_id}/decline",
    responses={
        200: {"model": InviteActionResponse},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
        409: {"model": ConflictResponse},
        502: {"model": HTTPExceptionResponse},
    },
)
@router.limiter.limit("5/minute")
async def decline_project_invite(
    request: RouteRequest,
    project_id: uuid.UUID,
    invite_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> InviteActionResponse:
    """Decline a pending project invite"""
    query = """
    WITH locked AS (
        SELECT member_id, kind, status, expires_at
        FROM project_invites
        WHERE id = $2 AND project_id = $1
        FOR UPDATE
    ), updated AS (
        UPDATE project_invites
        SET status = 'declined', responded_at = NOW() AT TIME ZONE 'utc'
        WHERE id = $2 AND project_id = $1
          AND status = 'pending'
          AND (expires_at IS NULL OR expires_at > NOW())
        RETURNING id
    ), expired_update AS (
        UPDATE project_invites
        SET status = 'expired'
        WHERE id = $2 AND project_id = $1
          AND status = 'pending'
          AND expires_at IS NOT NULL AND expires_at <= NOW()
    )
    SELECT
        locked.kind, locked.member_id, locked.status,
        (locked.expires_at IS NOT NULL AND locked.expires_at <= NOW()) AS expired,
        updated.id IS NOT NULL AS declined
    FROM locked
    LEFT JOIN updated ON TRUE;
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()
        try:
            row = await connection.fetchrow(query, project_id, invite_id)

            if not row:
                await tr.rollback()
                raise NotFoundError(_INVITE_NOT_FOUND)

            if row["expired"]:
                await tr.commit()
                raise ConflictError(_EXPIRED_INVITE)

            if not row["declined"] or not await _can_respond_to_invite(
                request,
                kind=row["kind"],
                member_id=row["member_id"],
                project_id=project_id,
                subject_id=session.identity.id,
            ):
                await tr.rollback()

                if not row["declined"]:
                    msg = f"This invite is already {row['status']}"
                    raise ConflictError(msg)

                msg = "You cannot respond to this invite"
                raise ForbiddenError(msg)
        except (BadGatewayError, ServiceUnavailableError):
            await tr.rollback()
            raise BadGatewayError(_AUTH_PERMS_FAILED)
        else:
            await tr.commit()
            return InviteActionResponse(id=invite_id, status="declined")


@router.delete(
    "/projects/{project_id}/invites/{invite_id}/revoke",
    responses={
        200: {"model": InviteActionResponse},
        403: {"model": ForbiddenResponse},
        404: {"model": NotFoundResponse},
        409: {"model": ConflictResponse},
    },
)
@router.limiter.limit("5/minute")
async def revoke_project_invite(
    request: RouteRequest,
    project_id: uuid.UUID,
    invite_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
) -> InviteActionResponse:
    """Revoke a pending project invite"""
    query = """
    WITH locked AS (
        SELECT invited_by, kind, status, expires_at
        FROM project_invites
        WHERE id = $2 AND project_id = $1
        FOR UPDATE
    ), updated AS (
        UPDATE project_invites
        SET status = 'revoked', responded_at = NOW() AT TIME ZONE 'utc'
        WHERE id = $2 AND project_id = $1
          AND status = 'pending'
          AND (expires_at IS NULL OR expires_at > NOW())
        RETURNING id
    ), expired_update AS (
        UPDATE project_invites
        SET status = 'expired'
        WHERE id = $2 AND project_id = $1
          AND status = 'pending'
          AND expires_at IS NOT NULL AND expires_at <= NOW()
    )
    SELECT
        locked.invited_by, locked.kind, locked.status,
        (locked.expires_at IS NOT NULL AND locked.expires_at <= NOW()) AS expired,
        updated.id IS NOT NULL AS revoked
    FROM locked
    LEFT JOIN updated ON TRUE;
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()
        try:
            row = await connection.fetchrow(query, project_id, invite_id)

            if not row:
                await tr.rollback()
                raise NotFoundError(_INVITE_NOT_FOUND)

            if row["expired"]:
                await tr.commit()
                raise ConflictError(_EXPIRED_INVITE)

            if not row["revoked"] or not await _can_revoke_invite(
                request,
                kind=row["kind"],
                invited_by=row["invited_by"],
                project_id=project_id,
                subject_id=session.identity.id,
            ):
                await tr.rollback()

                if not row["revoked"]:
                    msg = f"This invite is already {row['status']}"
                    raise ConflictError(msg)

                msg = "You cannot revoke this invite"
                raise ForbiddenError(msg)
        except (BadGatewayError, ServiceUnavailableError):
            await tr.rollback()
            raise BadGatewayError(_AUTH_PERMS_FAILED)
        else:
            await tr.commit()
            return InviteActionResponse(id=invite_id, status="revoked")


@router.get(
    "/projects/{project_id}/invites",
    dependencies=[check_any(has_role(Role.MANAGER), has_permissions(Project.edit))],
    responses={
        200: {"model": list[ProjectInvite]},
        403: {"model": ForbiddenResponse},
    },
)
@router.limiter.limit("10/minute")
async def list_project_invites(
    request: RouteRequest,
    project_id: uuid.UUID,
    session: Annotated[KanaeSession, Depends(use_session)],
    *,
    status: Optional[
        Literal["pending", "accepted", "declined", "revoked", "expired"]
    ] = None,
    kind: Optional[Literal["invite", "request"]] = None,
) -> list[ProjectInvite]:
    """View project invites, meant for managers to view"""
    args = [project_id]
    constraint = "WHERE invites.project_id = $1"

    if status and kind:
        constraint = (
            "WHERE invites.project_id = $1"
            " AND invites.status = $2 AND invites.kind = $3"
        )
        args.extend((status, kind))
    elif status or kind:
        column = "status" if status else "kind"
        constraint = f"WHERE invites.project_id = $1 AND invites.{column} = $2"
        args.append(status or kind)

    query = f"""
    WITH invites AS (
        SELECT
            project_invites.id,
            project_invites.project_id,
            jsonb_build_object('id', members.id, 'name', members.name) AS member,
            project_invites.invited_by,
            project_invites.kind,
            CASE
                WHEN project_invites.status = 'pending'
                     AND project_invites.expires_at IS NOT NULL
                     AND project_invites.expires_at <= NOW()
                THEN 'expired'
                ELSE project_invites.status
            END AS status,
            project_invites.message,
            project_invites.created_at,
            project_invites.responded_at,
            project_invites.expires_at
        FROM project_invites
        INNER JOIN members ON members.id = project_invites.member_id
    )
    SELECT
        invites.id, invites.project_id, invites.member,
        invites.invited_by, invites.kind, invites.status,
        invites.message, invites.created_at,
        invites.responded_at, invites.expires_at
    FROM invites
    {constraint}
    ORDER BY invites.created_at DESC
    """
    rows = await request.app.pool.fetch(query, *args)
    return [ProjectInvite(**dict(row)) for row in rows]


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
