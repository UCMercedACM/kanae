from __future__ import annotations

import datetime
import uuid
from typing import TYPE_CHECKING, Annotated, Literal, Optional

import asyncpg
from fastapi import Depends, HTTPException, Query, status
from pydantic import BaseModel
from supertokens_python.recipe.session import SessionContainer
from supertokens_python.recipe.session.framework.fastapi import verify_session
from utils.errors import (
    BadRequestException,
    HTTPExceptionMessage,
    NotFoundException,
    NotFoundMessage,
)
from utils.pages import KanaePages, KanaeParams, paginate
from utils.request import RouteRequest
from utils.router import KanaeRouter

if TYPE_CHECKING:
    ProjectType = Literal[
        "independent",
        "sig_ai",
        "sig_swe",
        "sig_cyber",
        "sig_data",
        "sig_arch",
        "sig_graph",
    ]

router = KanaeRouter(tags=["Projects"])


class ProjectMember(BaseModel, frozen=True):
    id: uuid.UUID
    name: str


class Projects(BaseModel):
    id: uuid.UUID
    name: str
    description: str
    link: str
    members: list[ProjectMember]
    type: ProjectType
    active: bool
    founded_at: datetime.datetime


class PartialProjects(BaseModel):
    id: uuid.UUID
    name: str
    description: str
    link: str
    type: ProjectType
    active: bool
    founded_at: datetime.datetime


@router.get("/projects")
async def list_projects(
    request: RouteRequest,
    name: Annotated[Optional[str], Query(min_length=3)] = None,
    since: Optional[datetime.datetime] = None,
    until: Optional[datetime.datetime] = None,
    active: Optional[bool] = True,
    *,
    params: Annotated[KanaeParams, Depends()],
) -> KanaePages[Projects]:
    """Search and filter a list of projects"""
    if since and until:
        raise BadRequestException(
            "Cannot specify both parameters. Must be only one be specified."
        )

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

    query = f"""
    SELECT 
        projects.id, projects.name, projects.description, projects.link,
        jsonb_agg(jsonb_build_object('id', members.id, 'name', members.name, 'role', members.role)) AS members, 
        projects.type, projects.active, projects.founded_at
    FROM projects
    INNER JOIN project_members ON project_members.project_id = projects.id
    INNER JOIN members ON project_members.member_id = members.id
    {constraint}
    """

    return await paginate(request.app.pool, query, *args, params=params)


@router.get(
    "/projects/{id}",
    responses={200: {"model": Projects}, 404: {"model": NotFoundMessage}},
)
async def get_project(request: RouteRequest, id: uuid.UUID) -> Projects:
    """Retrieve project details via ID"""
    query = """
    SELECT 
        projects.id, projects.name, projects.description, projects.link,
        jsonb_agg(jsonb_build_object('id', members.id, 'name', members.name)) AS members, 
        projects.type, projects.active, projects.founded_at
    FROM projects
    INNER JOIN project_members ON project_members.project_id = projects.id
    INNER JOIN members ON project_members.member_id = members.id
    WHERE projects.id = $1
    GROUP BY projects.id;
    """
    rows = await request.app.pool.fetchrow(query, id)
    if not rows:
        raise NotFoundException
    return Projects(**dict(rows))


class ModifiedProject(BaseModel):
    name: str
    description: str
    link: str


# Depends on scopes - Requires project lead and/or admin scopes
@router.put(
    "/projects/{id}",
    responses={200: {"model": Projects}, 404: {"model": NotFoundMessage}},
)
async def edit_event(
    request: RouteRequest,
    id: uuid.UUID,
    req: ModifiedProject,
    session: SessionContainer = Depends(verify_session),
):
    """Updates the specified project"""

    # todo: add query for admins
    query = """
    WITH project_member AS (
        SELECT members.id, members.role
        FROM projects
        INNER JOIN project_members ON project_members.project_id = projects.id
        INNER JOIN members ON project_members.member_id = members.id
        WHERE projects.id = $1
    )
    UPDATE projects
    SET
        name = $3,
        description = $4,
        link = $5
    WHERE
        id = $1
        AND EXISTS (SELECT 1 FROM project_member WHERE project_member.id = $2)
        AND EXISTS (
            SELECT 1 
            FROM members
            WHERE members.id = $2 AND members.project_role = 'lead'
        )
    RETURNING *;
    """

    rows = await request.app.pool.fetchrow(
        query, id, session.get_user_id(), *req.model_dump().values()
    )

    if not rows:
        raise NotFoundException(detail="Resource cannot be updated")
    return Projects(**dict(rows))


class DeleteResponse(BaseModel, frozen=True):
    message: str = "ok"


# Depends on scopes. Only admins should be able to delete them.
@router.delete(
    "/projects/{id}",
    responses={200: {"model": DeleteResponse}, 400: {"model": NotFoundMessage}},
)
async def delete_event(
    request: RouteRequest,
    id: uuid.UUID,
    session: SessionContainer = Depends(verify_session),
):
    """Deletes the specified project"""
    # todo: add query for admins

    query = """
    DELETE FROM projects
    WHERE id = $1 
    """
    status = await request.app.pool.execute(query, id)
    if status[-1] == "0":
        raise NotFoundException
    return DeleteResponse()


class CreateProject(BaseModel):
    name: str
    description: str
    link: str
    type: ProjectType
    active: bool
    founded_at: datetime.datetime


# todo: add tags along with projects
# Depends on roles, admins can only use this endpoint
@router.post("/projects/create", responses={200: {"model": PartialProjects}})
async def create_project(
    request: RouteRequest,
    req: CreateProject,
    session: SessionContainer = Depends(verify_session),
) -> PartialProjects:
    """Creates a new project given the provided data"""
    query = """
    INSERT INTO projects (name, description, link, type, active, founded_at)
    VALUES ($1, $2, $3, $4, $5, $6)
    RETURNING *;
    """
    rows = await request.app.pool.fetchrow(query, *req.model_dump().values())
    return PartialProjects(**dict(rows))


class JoinResponse(BaseModel):
    message: str


@router.post(
    "/projects/{id}/join",
    responses={200: {"model": JoinResponse}, 409: {"model": HTTPExceptionMessage}},
)
async def join_project(
    request: RouteRequest,
    id: uuid.UUID,
    session: SessionContainer = Depends(verify_session),
) -> JoinResponse:
    # The member is authenticated already, aka meaning that there is an existing member in our database
    query = """
    WITH insert_project_members AS (
        INSERT INTO project_members (project_id, member_id)
        VALUES ($1, $2)
        RETURNING member_id
    )
    UPDATE members
    SET project_role = 'member'
    WHERE id = (SELECT member_id FROM insert_project_members);
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()
        try:
            await connection.execute(query, id, session.get_user_id())
        except asyncpg.UniqueViolationError:
            await tr.rollback()
            raise HTTPException(
                detail="Authenticated member has already joined the requested project",
                status_code=status.HTTP_409_CONFLICT,
            )
        else:
            await tr.commit()
            return JoinResponse(message="ok")


class BulkJoinMember(BaseModel):
    id: uuid.UUID


# Depends on admin roles
@router.post(
    "/projects/{id}/bulk-join",
    responses={
        200: {"model": JoinResponse},
        400: {"model": HTTPExceptionMessage},
        409: {"model": HTTPExceptionMessage},
    },
)
async def bulk_join_project(
    request: RouteRequest,
    id: uuid.UUID,
    req: list[BulkJoinMember],
    session: SessionContainer = Depends(verify_session),
) -> JoinResponse:
    if len(req) > 10:
        raise BadRequestException("Must be less than 10 members")

    # The member is authenticated already, aka meaning that there is an existing member in our database
    query = """
    WITH insert_project_members AS (
        INSERT INTO project_members (project_id, member_id)
        VALUES ($1, $2)
        RETURNING member_id
    )
    UPDATE members
    SET project_role = 'member'
    WHERE id = (SELECT member_id FROM insert_project_members);
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()
        try:
            await connection.executemany(query, id, [entry.id for entry in req])
        except asyncpg.UniqueViolationError:
            await tr.rollback()
            raise HTTPException(
                detail="Authenticated member has already joined the requested project",
                status_code=status.HTTP_409_CONFLICT,
            )
        else:
            await tr.commit()
            return JoinResponse(message="ok")


@router.delete(
    "/projects/{id}/leave",
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundMessage}},
)
async def leave_project(
    request: RouteRequest,
    id: uuid.UUID,
    session: SessionContainer = Depends(verify_session),
) -> DeleteResponse:
    query = """
    DELETE FROM project_members
    WHERE project_id = $1 AND member_id = $2;
    """
    async with request.app.pool.acquire() as connection:
        status = await connection.execute(query, id, session.get_user_id())
        if status[-1] == "0":
            raise NotFoundException

        update_role_query = """
        UPDATE members
        SET project_role = 'unaffiliated'
        WHERE id = $1 AND NOT EXISTS (SELECT 1 FROM project_members WHERE member_id = $1);
        """
        await connection.execute(update_role_query, session.get_user_id())
        return DeleteResponse()


class UpgradeMemberRole(BaseModel):
    id: uuid.UUID
    role: Literal["former", "lead"]


@router.put(
    "/projects/{id}/member/modify",
    include_in_schema=False,
    responses={200: {"model": DeleteResponse}},
)
async def modify_member(
    request: RouteRequest,
    id: uuid.UUID,
    req: UpgradeMemberRole,
    session: SessionContainer = Depends(verify_session),
):
    """Undocumented route to just upgrade/demote member role in projects"""
    query = """
    WITH upgrade_member AS (
        SELECT members.id
        FROM projects
        INNER JOIN project_members ON project_members.project_id = projects.id
        INNER JOIN members ON project_members.member_id = members.id
        WHERE projects.id = $1
    )
    UPDATE members
    SET project_role = $3
    WHERE members.id = $2 AND EXISTS (SELECT 1 FROM upgrade_member WHERE upgrade_member.id = $2);
    """
    await request.app.pool.execute(query, id, req.id, req.role)
    return DeleteResponse()


@router.get("/projects/me", responses={200: {"model": PartialProjects}})
async def get_my_projects(
    request: RouteRequest, session: SessionContainer = Depends(verify_session)
) -> list[PartialProjects]:
    """Get all projects associated with the authenticated user"""
    query = """
    SELECT 
        projects.id, projects.name, projects.description, projects.link,
        projects.type, projects.active, projects.founded_at
    FROM projects
    INNER JOIN project_members ON project_members.project_id = projects.id
    INNER JOIN members ON project_members.member_id = members.id
    WHERE members.id = $1
    GROUP BY projects.id;
    """

    records = await request.app.pool.fetch(query, session.get_user_id())
    return [PartialProjects(**dict(row)) for row in records]


class ProjectTags(BaseModel):
    id: uuid.UUID
    title: str
    description: str


@router.get("/projects/tags")
async def get_project_tags(
    request: RouteRequest,
    title: Annotated[Optional[str], Query(min_length=3)],
    *,
    params: Annotated[KanaeParams, Depends()],
) -> KanaePages[ProjectTags]:
    """Get all tags that can be used in projects or sort for a list of tags"""
    query = """
    SELECT id, title, description
    FROM tags
    ORDER BY title DESC
    """

    if title:
        query = """
        SELECT id, title, description
        FROM projects
        WHERE title % $1
        ORDER BY similarity(title, $1) DESC
        """

    args = (title) if title else ()
    return await paginate(request.app.pool, query, *args, params=params)


@router.get(
    "/projects/tags/{id}",
    responses={200: {"model": ProjectTags}, 404: {"model": NotFoundMessage}},
)
async def get_project_tag_by_id(request: RouteRequest, id: uuid.UUID) -> ProjectTags:
    """Get tag via ID"""
    query = """
    SELECT id, title, description
    FROM projects
    WHERE id = $1;
    """

    rows = await request.app.pool.fetchrow(query, id)
    if not rows:
        raise NotFoundException
    return ProjectTags(**dict(rows))


class ModifyProjectTag(BaseModel):
    title: str
    description: str


@router.put(
    "/projects/tags/{id}",
    responses={200: {"model": ProjectTags}, 404: {"model": NotFoundMessage}},
)
async def edit_project_tag(
    request: RouteRequest,
    id: uuid.UUID,
    req: ModifiedProject,
    session: SessionContainer = Depends(verify_session),
) -> ProjectTags:
    """Modify specified project tag"""
    query = """
    UPDATE tags
    SET
        title = $2
        description = $3
    WHERE id = $1
    RETURNING *;
    """
    rows = await request.app.pool.fetchrow(query, id, *req.model_dump().values())
    if not rows:
        raise NotFoundException(detail="Resource cannot be updated")
    return ProjectTags(**dict(rows))


@router.delete(
    "/projects/tags/{id}",
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundMessage}},
)
async def delete_project_tag(
    request: RouteRequest,
    id: uuid.UUID,
    session: SessionContainer = Depends(verify_session),
) -> DeleteResponse:
    """Remove specified project tag"""
    query = """
    DELETE FROM tags
    WHERE id = $1;
    """

    query_status = await request.app.pool.execute(query, id)
    if query_status[-1] == "0":
        raise NotFoundException
    return DeleteResponse()


@router.post("/projects/tags/create", responses={200: {"model": ProjectTags}})
async def create_project_tags(
    request: RouteRequest,
    req: ModifyProjectTag,
    session: SessionContainer = Depends(verify_session),
) -> ProjectTags:
    """Create project tag"""
    query = """
    INSERT INTO tags (title, description)
    VALUES ($1, $2)
    RETURNING *;
    """
    rows = await request.app.pool.fetchrow(query, *req.model_dump().values())
    return ProjectTags(**dict(rows))


@router.post("/projects/tags/bulk-create", responses={200: {"model": DeleteResponse}})
async def bulk_create_project_tags(
    request: RouteRequest,
    req: list[ModifyProjectTag],
    session: SessionContainer = Depends(verify_session),
) -> DeleteResponse:
    """Bulk-create project tags"""
    query = """
    INSERT INTO tags (title, description)
    VALUES ($1, $2)
    """
    await request.app.pool.executemany(
        query, [(tag.title, tag.description) for tag in req]
    )
    return DeleteResponse()
