-- Invite links and opt-in discovery by e-mail.
--
-- An invite is a random token (stored hashed) that makes whoever opens it a
-- contact of the inviter, without a request: sharing the link is the
-- inviter's consent, opening it the other person's.
--
-- email_hash is SHA-256("securelyhello-email|" + lower(email)), the same
-- value apps compute from their address book. Only users who turn on
-- email_discoverable can be matched.

CREATE TABLE invites (
  token_hash bytea       PRIMARY KEY,
  inviter_id uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  max_uses   integer     NOT NULL,
  uses       integer     NOT NULL DEFAULT 0,
  revoked_at timestamptz,
  CONSTRAINT invites_uses CHECK (uses >= 0 AND uses <= max_uses)
);
CREATE INDEX invites_inviter ON invites (inviter_id);

ALTER TABLE users ADD COLUMN email_discoverable boolean NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN email_hash bytea;
UPDATE users SET email_hash = sha256(convert_to('securelyhello-email|' || lower(email), 'UTF8'));
CREATE INDEX users_email_hash ON users (email_hash) WHERE email_discoverable;
