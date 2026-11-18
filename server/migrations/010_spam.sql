-- Spam defenses (see src/spam.js). A restricted account can't send new
-- contact requests until restricted_until; existing contacts still work.
ALTER TABLE users ADD COLUMN restricted_until timestamptz;
ALTER TABLE users ADD COLUMN restricted_reason text;

CREATE INDEX reports_reported_recent ON reports (reported_id, created_at);
CREATE INDEX blocks_blocked_recent ON blocks (blocked_id, created_at);
CREATE INDEX contact_requests_sender_recent ON contact_requests (sender_id, updated_at);
