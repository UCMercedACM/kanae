-- SELECT members.id,
--     (SELECT jsonb_agg(json_build_object('id', projects.id, 'name', projects.name)) FROM projects WHERE projects.id = project_members.project_id) AS member_projects
-- FROM members
--     INNER JOIN project_members ON members.id = project_members.member_id
--     INNER JOIN events_members ON members.id = events_members.member_id
-- GROUP BY members.id;
-- SELECT jsonb_agg(jsonb_build_object('id', projects.id, 'name', projects.name)) AS projects, jsonb_agg(jsonb_build_object('id', events.id, 'name', events.name)) AS events
-- FROM project_members, events_members
-- INNER JOIN projects ON project_members.project_id = projects.id
-- INNER JOIN events ON events_members.event_id = events.id;
SELECT jsonb_agg_strict(projects.*) AS projects
FROM members
    INNER JOIN project_members ON members.id = project_members.member_id
    INNER JOIN projects ON project_members.project_id = projects.id
WHERE members.id = '69268f99-08ac-4ca9-8007-f94f8092e396'
GROUP BY members.id;

SELECT events.id, events.name
FROM members
    INNER JOIN events_members ON members.id = events_members.member_id
    INNER JOIN events ON events_members.event_id = events.id
WHERE members.id = '69268f99-08ac-4ca9-8007-f94f8092e396'
GROUP BY events.id;

SELECT jsonb_agg_strict(projects.*) AS projects
FROM members
    INNER JOIN project_members ON members.id = project_members.member_id
    AND project_members.role == 'member'
    INNER JOIN projects ON project_members.project_id = projects.id
WHERE members.id = '69268f99-08ac-4ca9-8007-f94f8092e396'
GROUP BY members.id;
SELECT jsonb_agg(
        jsonb_build_object('id', projects.id, 'name', projects.name)
    ) AS projects
FROM projects
    INNER JOIN project_members ON projects.id = project_members.project_id
    INNER JOIN members ON project_members.member_id = members.id
GROUP BY members.name,
    projects.name;