-- Users who turn discovery off only show up in search when someone types
-- their exact username.
ALTER TABLE users ADD COLUMN discoverable boolean NOT NULL DEFAULT true;
