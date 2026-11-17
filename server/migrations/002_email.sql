-- E-mail verification and password reset.
--
-- A code is 6 digits, valid for a short time, allowed a few wrong guesses and
-- stored only as a hash. One live code per (user, purpose): asking again
-- replaces the previous one.

ALTER TABLE users ADD COLUMN email_verified_at timestamptz;

CREATE TABLE email_codes (
  user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  purpose    text        NOT NULL,
  code_hash  bytea       NOT NULL,
  attempts   integer     NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, purpose),
  CONSTRAINT email_codes_purpose CHECK (purpose IN ('verify', 'reset'))
);

CREATE INDEX email_codes_expires_idx ON email_codes (expires_at);
