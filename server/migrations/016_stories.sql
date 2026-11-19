-- Stories (1.1). Additive only: 1.0 apps never see any of this.
--
-- What a device can take beyond 1.0 (e.g. 'stories'). A 1.0 device never
-- sets it, so nobody seals a story key to a device that couldn't open it.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS capabilities text[] NOT NULL DEFAULT '{}';

-- A story: who posted it and when it goes. The content is encrypted with a
-- per-story key the server never sees; photos and videos are ordinary
-- encrypted attachments that expire with the story.
CREATE TABLE IF NOT EXISTS stories (
  id             uuid        PRIMARY KEY,
  owner_id       uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at     timestamptz NOT NULL DEFAULT now(),
  expires_at     timestamptz NOT NULL,
  attachment_ids uuid[]      NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS stories_owner_idx ON stories (owner_id, created_at);
CREATE INDEX IF NOT EXISTS stories_expires_idx ON stories (expires_at);

-- The story key for one audience device, inside a v3 envelope (ciphertext).
CREATE TABLE IF NOT EXISTS story_keys (
  story_id     uuid NOT NULL REFERENCES stories (id) ON DELETE CASCADE,
  device_id    uuid NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
  recipient_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  envelope     text NOT NULL,
  PRIMARY KEY (story_id, device_id)
);
CREATE INDEX IF NOT EXISTS story_keys_device_idx ON story_keys (device_id);
