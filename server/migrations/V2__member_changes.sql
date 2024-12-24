-- Revision Version: V2
-- Revises: V1
-- Creation Date: 2024-12-22 05:24:08.318648+00:00 UTC
-- Reason: member_changes

ALTER TABLE IF EXISTS members DROP COLUMN created_at;
ALTER TABLE IF EXISTS events DROP COLUMN created_at;

-- Members
ALTER TABLE IF EXISTS members ADD COLUMN email TEXT;
ALTER TABLE IF EXISTS members ADD COLUMN created_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc');

-- Events
-- Only SIG Leads + Admins can create events, the roles will be added later
ALTER TABLE IF EXISTS events ADD COLUMN creator_id UUID REFERENCES members (id) ON DELETE CASCADE ON UPDATE NO ACTION;
ALTER TABLE IF EXISTS events ADD COLUMN created_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() AT TIME ZONE 'utc');

-- Index for later searching use
CREATE INDEX IF NOT EXISTS events_creator_idx ON events (creator_id);

