-- Revision Version: V1
-- Revises: V0
-- Creation Date: 2024-11-01 03:51:31.617115+00:00 UTC
-- Reason: initial_migration

CREATE TABLE IF NOT EXISTS members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc')
);

CREATE TYPE event_type AS ENUM (
    'general',
    'sig_ai',
    'sig_swe',
    'sig_cyber',
    'sig_data',
    'sig_arch',
    'social',
    'misc'
);

-- This table basically covers workshops and events all at once
CREATE TABLE IF NOT EXISTS events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT,
    start_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc'),
    end_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc'),
    location TEXT,
    alt_link TEXT DEFAULT '',
    type event_type DEFAULT 'misc',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc')
);

-- This would allow for faster lookups for events
CREATE INDEX IF NOT EXISTS events_name_idx ON events (name);
CREATE INDEX IF NOT EXISTS events_name_lower_idx ON events (LOWER(name));

CREATE TABLE IF NOT EXISTS events_members (
    event_id UUID REFERENCES events (id) ON DELETE CASCADE ON UPDATE NO ACTION,
    member_id UUID REFERENCES members (id) ON DELETE CASCADE ON UPDATE NO ACTION,
    PRIMARY KEY (event_id, member_id)
);