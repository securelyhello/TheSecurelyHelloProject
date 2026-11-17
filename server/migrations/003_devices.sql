-- Multiple devices per account, each with its own keys (protocol v3).
--
-- A device publishes an identity (Ed25519 signing key + X25519 key), a signed
-- prekey and a stock of one-time prekeys. Senders run X3DH against these and
-- then a Double Ratchet per device pair, so every device has forward-secret
-- sessions of its own. Private keys never leave the device.
--
-- A session token is bound to the device that registered with it; removing
-- the device revokes its sessions.

CREATE TABLE devices (
  id                       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                  uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  name                     text        NOT NULL DEFAULT '',
  signing_public_key       text        NOT NULL,
  identity_public_key      text        NOT NULL,
  signed_prekey_id         integer     NOT NULL,
  signed_prekey            text        NOT NULL,
  signed_prekey_signature  text        NOT NULL,
  push_platform            text,
  push_token               text,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  last_seen_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT devices_name_length CHECK (char_length(name) <= 64),
  CONSTRAINT devices_push_platform CHECK (push_platform IS NULL OR push_platform IN ('fcm'))
);

CREATE INDEX devices_user_idx ON devices (user_id);
CREATE UNIQUE INDEX devices_push_token_key ON devices (push_token) WHERE push_token IS NOT NULL;

CREATE TABLE one_time_prekeys (
  device_id  uuid    NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
  key_id     integer NOT NULL,
  public_key text    NOT NULL,
  PRIMARY KEY (device_id, key_id)
);

ALTER TABLE sessions ADD COLUMN device_id uuid REFERENCES devices (id) ON DELETE CASCADE;
CREATE INDEX sessions_device_idx ON sessions (device_id);

-- Account-level keys are replaced by per-device keys.
ALTER TABLE users ALTER COLUMN signing_public_key DROP NOT NULL;
ALTER TABLE users ALTER COLUMN encryption_public_key DROP NOT NULL;
UPDATE users SET signing_public_key = NULL, encryption_public_key = NULL;
