-- Blocking and abuse reports.
--
-- A block removes the contact edge and keeps the blocked user from finding
-- or reaching the blocker. It is silent: the blocked user is not told.
-- Reports go to the operator. The server can't read messages, so a report
-- contains only what the reporter chooses to share.

CREATE TABLE blocks (
  blocker_id uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  blocked_id uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id),
  CONSTRAINT blocks_not_self CHECK (blocker_id <> blocked_id)
);

CREATE INDEX blocks_blocked_idx ON blocks (blocked_id);

CREATE TABLE reports (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id uuid        REFERENCES users (id) ON DELETE SET NULL,
  reported_id uuid        REFERENCES users (id) ON DELETE SET NULL,
  reason      text        NOT NULL,
  details     text        NOT NULL DEFAULT '',
  evidence    jsonb       NOT NULL DEFAULT '[]',
  status      text        NOT NULL DEFAULT 'open',
  created_at  timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  CONSTRAINT reports_reason CHECK (reason IN ('spam', 'harassment', 'impersonation', 'illegal', 'other')),
  CONSTRAINT reports_status CHECK (status IN ('open', 'resolved', 'dismissed')),
  CONSTRAINT reports_details_length CHECK (char_length(details) <= 2000)
);

CREATE INDEX reports_status_idx ON reports (status, created_at);

-- Operator suspension (see POST /api/admin/users/:id/suspend).
ALTER TABLE users ADD COLUMN suspended_at timestamptz;
