import datetime
import uuid
from typing import Annotated, Literal, Optional

import asyncpg
from fastapi import Depends, HTTPException, Query
from pydantic import BaseModel
from utils.auth import use_session
from utils.checks import Project, Role, check_any, has_permissions, has_role
from utils.errors import BadRequestError, ConflictError, NotFoundError
from utils.ory import KanaeSession
from utils.pages import KanaePages, KanaeParams, paginate
from utils.request import RouteRequest
from utils.responses import (
    ConflictResponse,
    DeleteResponse,
    HTTPExceptionResponse,
    JoinResponse,
    NotFoundResponse,
)
from utils.router import KanaeRouter

router = KanaeRouter(tags=["Projects"])


class ProjectMember(BaseModel, frozen=True):
    id: uuid.UUID
    name: str


class Projects(BaseModel, frozen=True):
    id: uuid.UUID
    name: str
    description: str
    link: str
    type: Literal[
        "independent",
        "sig_ai",
        "sig_swe",
        "sig_cyber",
        "sig_data",
        "sig_arch",
        "sig_graph",
    ]
    tags: Optional[list[str]] = None
    active: bool
    founded_at: datetime.datetime


class FullProjects(BaseModel, frozen=True):
    id: uuid.UUID
    name: str
    description: str
    link: str
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
    tags: Optional[list[str]] = None
    active: bool
    founded_at: datetime.datetime


@router.get("/projects")
async def list_projects(
    request: RouteRequest,
    name: Annotated[Optional[str], Query(min_length=3)] = None,
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

    args = []
    time_constraint = ""

    if name:
        if since or until:
            if since:
                time_constraint = "AND projects.founded_at >= $2"
                args.append(since)
            elif until:
                time_constraint = "AND projects.founded_at <= $2"
                args.append(until)

        constraint = f"WHERE projects.name % $1 {time_constraint} GROUP BY projects.id ORDER BY similarity(projects.name, $1) DESC"
        args.insert(0, name)
    elif active is not None:
        constraint = "WHERE projects.active = $1 GROUP BY projects.id"
        args.append(active)
    else:
        if since:
            time_constraint = "projects.founded_at >= $1 AND projects.active = $2"
            args.extend((since, active))
        elif until:
            time_constraint = "projects.founded_at <= $1 AND projects.active = $2"
            args.extend((until, active))
        constraint = f"WHERE {time_constraint} GROUP BY projects.id"

    # ruff: noqa: S608
    query = f"""
    SELECT
        projects.id, projects.name, projects.description, projects.link,
        jsonb_agg(jsonb_build_object('id', members.id, 'name', members.name, 'role', project_members.role)) AS members,
        projects.type, projects.active, projects.founded_at
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
        projects.type, projects.active, projects.founded_at
    FROM projects
    INNER JOIN project_members ON project_members.project_id = projects.id
    INNER JOIN members ON project_members.member_id = members.id
    WHERE projects.id = $1
    GROUP BY projects.id;
    """
    rows = await request.app.pool.fetchrow(query, project_id)
    if not rows:
        raise NotFoundError
    return FullProjects(**dict(rows))


class ModifiedProject(BaseModel, frozen=True):
    name: str
    description: str
    link: str


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
    """
    status = await request.app.pool.execute(query, project_id)
    if status[-1] == "0":
        raise NotFoundError
    return DeleteResponse()


class CreateProject(BaseModel, frozen=True):
    name: str
    description: str
    link: str
    type: Literal[
        "independent",
        "sig_ai",
        "sig_swe",
        "sig_cyber",
        "sig_data",
        "sig_arch",
        "sig_graph",
    ]
    tags: Optional[list[str]] = None
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
    INSERT INTO projects (name, description, link, type, active, founded_at)
    VALUES ($1, $2, $3, $4, $5, $6)
    RETURNING *;
    """

    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()

        project_rows = await connection.fetchrow(
            query, *req.model_dump(exclude={"tags"}).values()
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
            await connection.executemany(query, project_id, [entry.id for entry in req])
        except asyncpg.UniqueViolationError:
            await tr.rollback()
            msg = "Authenticated member has already joined the requested project"
            raise ConflictError(msg)
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
