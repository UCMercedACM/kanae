SELECT members.id,
    (SELECT jsonb_agg(json_build_object('id', projects.id, 'name', projects.name)) FROM projects WHERE projects.id = project_members.project_id) AS member_projects
FROM members
    INNER JOIN project_members ON members.id = project_members.member_id
    INNER JOIN events_members ON members.id = events_members.member_id
GROUP BY members.id;