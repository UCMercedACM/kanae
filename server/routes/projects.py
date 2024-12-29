import datetime
import uuid
from typing import Annotated, Literal, Optional

from fastapi import Query
from pydantic import BaseModel
from utils.errors import BadRequestException
from utils.request import RouteRequest
from utils.router import KanaeRouter

router = KanaeRouter(tags=["Projects"])

class ProjectMembers(BaseModel, frozen=True):
    id: uuid.UUID
    name: str
class Projects(BaseModel):
    id: uuid.UUID
    name: str
    description: str
    link: str
    members: list[ProjectMembers]
    type: Literal["independent", "sig_ai", "sig_swe", "sig_cyber", "sig_data", "sig_arch", "sig_graph"]
    active: bool
    founded_at: datetime.datetime

def _inject_args(since: Optional[datetime.datetime], until: Optional[datetime.datetime], active: Optional[bool], args: list) -> list:
    if since:
        args.extend((since, active))
    elif until:
        args.extend((until, active))
    return args
    
#  name: Annotated[Optional[str], Query(min_length=3)], since: Optional[datetime.datetime], until: Optional[datetime.datetime]
@router.get("/projects")
async def list_projects(request: RouteRequest, name: Annotated[Optional[str], Query(min_length=3)] = None, since: Optional[datetime.datetime] = None, until: Optional[datetime.datetime] = None, active: Optional[bool] = True):
    if since and until:
        raise BadRequestException("Cannot specify both parameters. Must be only one be specified.")
    
    constraint = ""
    args = []
    
    # There is probably a more optimized way of doing this - Noelle
    if name and (since or until):
        time_constraint = ""
        args.append(name)
        if since:
            time_constraint = "projects.founded_at >= $2"
            args.extend((since, active))
        elif until:
            time_constraint = "projects.founded_at <= $2"
            args.extend((until, active))
        constraint = f"WHERE projects.name % $1 AND  {time_constraint} AND projects.active = $3 GROUP BY projects.id ORDER BY similarity(projects.name, $1) DESC"
    else:
        if since:
            constraint = "WHERE projects.founded_at >= $1 AND projects.active = $2 GROUP BY projects.id"
            args.extend((since, active))
        elif until:
            constraint = "WHERE projects.founded_at <= $1 AND projects.active = $2 GROUP BY projects.id"
            args.extend((until, active))
        

        
    query = f"""
    SELECT 
        projects.id, projects.name, projects.description, projects.link, 
        jsonb_agg(jsonb_build_object('id', members.id, 'name', members.name)) AS members, 
        projects.type, projects.active, projects.founded_at
    FROM projects
    LEFT OUTER JOIN project_members ON project_members.project_id = projects.id
    LEFT OUTER JOIN members ON project_members.member_id = members.id
    {constraint};
    """

    print(query)
    print(args)
        
    
        
        
    
    records = await request.app.pool.fetch(query, *args)
    return [Projects(**dict(project)) for project in records]