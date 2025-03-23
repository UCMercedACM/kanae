import datetime
import uuid
from typing import Annotated, Literal, Optional

import asyncpg
from fastapi import Depends, HTTPException, Query, status
from pydantic import BaseModel
from supertokens_python.recipe.session import SessionContainer
from supertokens_python.recipe.session.framework.fastapi import verify_session
from supertokens_python.recipe.userroles import UserRoleClaim
from utils.errors import (
    BadRequestException,
    HTTPExceptionMessage,
    NotFoundException,
    NotFoundMessage,
)
from utils.pages import KanaePages, KanaeParams, paginate
from utils.request import RouteRequest
from utils.responses import DeleteResponse, JoinResponse
from utils.roles import has_admin_role, has_any_role
from utils.router import KanaeRouter

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
    type: Literal[
        "independent",
        "sig_ai",
        "sig_swe",
        "sig_cyber",
        "sig_data",
        "sig_arch",
        "sig_graph",
    ]
    tags: Optional[list[str]]
    active: bool
    founded_at: datetime.datetime


class PartialProjects(BaseModel):
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
    tags: Optional[list[str]]
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

    # ruff: noqa: S608
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


@router.put(
    "/projects/{id}",
    responses={200: {"model": Projects}, 404: {"model": NotFoundMessage}},
)
@has_any_role("admin", "leads")
@router.limiter.limit("3/minute")
async def edit_project(
    request: RouteRequest,
    id: uuid.UUID,
    req: ModifiedProject,
    session: Annotated[SessionContainer, Depends(verify_session())],
):
    """Updates the specified project"""

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

    roles = await session.get_claim_value(UserRoleClaim)

    if roles and "admin" in roles:
        # Effectively admins can override projects
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
            name = $2,
            description = $3,
            link = $4
        WHERE
            id = $1
        RETURNING *;
        """

    args = (id) if roles and "admin" in roles else (id, session.get_user_id())
    rows = await request.app.pool.fetchrow(query, *args, *req.model_dump().values())

    if not rows:
        raise NotFoundException(detail="Resource cannot be updated")
    return Projects(**dict(rows))


@router.delete(
    "/projects/{id}",
    responses={200: {"model": DeleteResponse}, 404: {"model": NotFoundMessage}},
)
@has_admin_role()
@router.limiter.limit("3/minute")
async def delete_project(
    request: RouteRequest,
    id: uuid.UUID,
    session: Annotated[SessionContainer, Depends(verify_session())],
):
    """Deletes the specified project"""
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
    responses={200: {"model": PartialProjects}, 422: {"model": HTTPExceptionMessage}},
)
# @has_admin_role()
@router.limiter.limit("5/minute")
async def create_project(
    request: RouteRequest,
    req: CreateProject,
    # session: Annotated[SessionContainer, Depends(verify_session())],
) -> PartialProjects:
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
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                )
            else:
                await tr.commit()

        return PartialProjects(**dict(project_rows), tags=req.tags)


@router.post(
    "/projects/{id}/join",
    responses={200: {"model": JoinResponse}, 409: {"model": HTTPExceptionMessage}},
)
@router.limiter.limit("5/minute")
async def join_project(
    request: RouteRequest,
    id: uuid.UUID,
    # session: Annotated[SessionContainer, Depends(verify_session())],
) -> JoinResponse:
    # The member is authenticated already, aka meaning that there is an existing member in our database
    query = """
    WITH insert_project_members AS (
        INSERT INTO project_members (project_id, member_id)
        VALUES ($1, $2)
        RETURNING member_id
    )
    UPDATE members
    SET role = 'member'
    WHERE id = (SELECT member_id FROM insert_project_members);
    """
    async with request.app.pool.acquire() as connection:
        tr = connection.transaction()
        await tr.start()
        try:
            await connection.execute(query, id, "1a83e6bb-1096-4bdc-80eb-eb24a87cf190")
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


@router.post(
    "/projects/{id}/bulk-join",
    responses={
        200: {"model": JoinResponse},
        409: {"model": HTTPExceptionMessage},
    },
)
@has_any_role("admin", "leads")
@router.limiter.limit("1/minute")
async def bulk_join_project(
    request: RouteRequest,
    id: uuid.UUID,
    req: list[BulkJoinMember],
    session: Annotated[SessionContainer, Depends(verify_session())],
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
    SET role = 'member'
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
@router.limiter.limit("5/minute")
async def leave_project(
    request: RouteRequest,
    id: uuid.UUID,
    session: Annotated[SessionContainer, Depends(verify_session())],
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
@has_admin_role()
@router.limiter.limit("3/minute")
async def modify_member(
    request: RouteRequest,
    id: uuid.UUID,
    req: UpgradeMemberRole,
    session: Annotated[SessionContainer, Depends(verify_session())],
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
@router.limiter.limit("15/minute")
async def get_my_projects(
    request: RouteRequest,
    session: Annotated[SessionContainer, Depends(verify_session())],
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
