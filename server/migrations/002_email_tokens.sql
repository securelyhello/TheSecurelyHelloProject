-- Securely Hello: e-mail verification and password-reset codes.
--
-- * users.email_verified_at   set when the user proves the mailbox (a verify
--                             code, or a successful password reset). NULL =
--                             unverified; verification is soft (nothing is
--                             blocked on it).
-- * auth_tokens               one live 6-digit code per (user, purpose). Only
--                             SHA-256("purpose:userId:code") is stored; a code
--                             dies after 5 wrong attempts, on use, or at
--                             expires_at (expired rows are swept hourly).

ALTER TABLE users ADD COLUMN email_verified_at timestamptz;

CREATE TABLE auth_tokens (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  purpose    text        NOT NULL,
  code_hash  bytea       NOT NULL,
  attempts   smallint    NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  CONSTRAINT auth_tokens_purpose CHECK (purpose IN ('password_reset', 'email_verify')),
  CONSTRAINT auth_tokens_user_purpose UNIQUE (user_id, purpose)
);

CREATE INDEX auth_tokens_expires_idx ON auth_tokens (expires_at);
