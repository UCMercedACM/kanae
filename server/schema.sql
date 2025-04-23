CREATE TYPE event_type AS ENUM (
    'general',
    'sig_ai',
    'sig_swe',
    'sig_cyber',
    'sig_data',
    'sig_arch',
    'sig_graph',
    'social',
    'misc'
);

CREATE TYPE project_role AS ENUM (
    'unaffiliated',
    'member',
    'former',
    'lead',
    'manager'
);

CREATE TABLE IF NOT EXISTS members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT,
    email TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc')
);

-- This table basically covers workshops and events all at once
CREATE TABLE IF NOT EXISTS events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT,
    start_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc'),
    end_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc'),
    location TEXT,
    type event_type DEFAULT 'misc',
    creator_id UUID REFERENCES members (id) ON DELETE CASCADE ON UPDATE NO ACTION,
    attendance_hash TEXT,
    attendance_code TEXT,
    timezone TEXT DEFAULT 'UTC',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc')
);


-- This would allow for faster lookups for events
CREATE INDEX IF NOT EXISTS events_name_idx ON events (name);
CREATE INDEX IF NOT EXISTS events_name_lower_idx ON events (LOWER(name));
CREATE INDEX IF NOT EXISTS events_creator_idx ON events (creator_id);

CREATE TABLE IF NOT EXISTS events_members (
    event_id UUID REFERENCES events (id) ON DELETE CASCADE ON UPDATE NO ACTION,
    member_id UUID REFERENCES members (id) ON DELETE CASCADE ON UPDATE NO ACTION,
    planned BOOLEAN DEFAULT NULL,
    attended BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (event_id, member_id)
);

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
    active BOOL DEFAULT TRUE,
    founded_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc')
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
    role project_role DEFAULT 'unaffiliated',
    joined_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc'),
    PRIMARY KEY (project_id, member_id)
);