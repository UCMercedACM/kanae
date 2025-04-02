SELECT members.id,
    members.name,
    jsonb_agg(to_jsonb(row(projects.id, projects.name))) AS user_projects,
    members.created_at
FROM members
    INNER JOIN project_members ON members.id = project_members.member_id
    INNER JOIN events_members ON members.id = events_members.member_id
    INNER JOIN projects ON projects.id = project_members.project_id
    INNER JOIN events ON events.id = events_members.event_id
GROUP BY members.id;