-- Revision Version: V3
-- Revises: V2
-- Creation Date: 2024-12-26 09:27:35.701551+00:00 UTC
-- Reason: projects

CREATE TYPE project_type AS ENUM (
    'independent',
    'sig_ai',
    'sig_swe',
    'sig_cyber',
    'sig_data',
    'sig_arch',
    'sig_graph'
);

-- Projects by themselves, are basically the same type of relationship compared to events
-- They are many-to-many
-- Ex. A member can be in multiples projects (e.g. Website, UniFoodi, Fishtank, etc), and a project can have multiple members
CREATE TABLE IF NOT EXISTS projects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT,
    link TEXT,
    type project_type DEFAULT 'independent',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc')
);

-- A project also is associated with a set of "tags"
-- Meaning that many projects can have many tags
-- This basically implies that we need bridge tables to overcome the gap.
CREATE TABLE IF NOT EXISTS tags (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT
);

-- Entirely overkill index for "performance reasons"
-- Realistically, given the scale of the data now, it doesn't matter
CREATE INDEX IF NOT EXISTS tags_title_idx ON tags (title);
CREATE INDEX IF NOT EXISTS tags_title_lower_idx ON tags (LOWER(title));

-- Bridge table for Projects <--> Tags
-- Many need to adjust the cascade for deletions later.
CREATE TABLE IF NOT EXISTS project_tags (
    project_id UUID REFERENCES projects (id) ON DELETE CASCADE ON UPDATE NO ACTION,
    tag_id INTEGER REFERENCES tags (id) ON DELETE NO ACTION ON UPDATE NO ACTION,
    PRIMARY KEY (project_id, tag_id)
);

-- Bridge table for Projects <--> Members
-- Many need to adjust the cascade for deletions later.
CREATE TABLE IF NOT EXISTS project_members (
    project_id UUID REFERENCES projects (id) ON DELETE CASCADE ON UPDATE NO ACTION,
    member_id UUID REFERENCES members (id) ON DELETE CASCADE ON UPDATE NO ACTION,
    PRIMARY KEY (project_id, member_id)
);