-- Revision Version: V4
-- Revises: V3
-- Creation Date: 2025-02-10 05:03:02.890358+00:00 UTC
-- Reason: attendance_hash

ALTER TABLE IF EXISTS events ADD COLUMN attendance_hash TEXT;
ALTER TABLE IF EXISTS events ADD COLUMN attendance_code TEXT;

-- We need to make sure that we are storing the correct timezone for events
ALTER TABLE IF EXISTS events ADD COLUMN timezone TEXT DEFAULT 'UTC';

-- Column to check whether a user either planned to attend or has attended the event
ALTER TABLE IF EXISTS events_members ADD COLUMN planned BOOLEAN DEFAULT NULL;
ALTER TABLE IF EXISTS events_members ADD COLUMN attended BOOLEAN DEFAULT FALSE;