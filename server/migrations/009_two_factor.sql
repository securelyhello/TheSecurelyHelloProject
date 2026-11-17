-- Two-step verification (TOTP, RFC 6238) with one-time recovery codes.
--
-- totp_secret is AES-256-GCM encrypted when TOTP_ENCRYPTION_KEY is set
-- ("g:" prefix), otherwise stored as is ("p:"). totp_last_step stops a code
-- from being used twice.

ALTER TABLE users ADD COLUMN totp_secret text;
ALTER TABLE users ADD COLUMN totp_pending_secret text;
ALTER TABLE users ADD COLUMN totp_enabled_at timestamptz;
ALTER TABLE users ADD COLUMN totp_last_step bigint;

CREATE TABLE totp_recovery_codes (
  user_id   uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  code_hash bytea       NOT NULL,
  used_at   timestamptz,
  PRIMARY KEY (user_id, code_hash)
);
