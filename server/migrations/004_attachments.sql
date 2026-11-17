-- Encrypted attachments.
--
-- The app encrypts a file on the device with a fresh random key and uploads
-- only the ciphertext. The key, a SHA-256 of the ciphertext, the file name
-- and its type travel inside the end-to-end encrypted message, so the server
-- holds opaque bytes it cannot read and doesn't know what they are. Blobs
-- expire (ATTACHMENT_TTL_DAYS) and are swept.

CREATE TABLE attachments (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  uploader_id uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  size        integer     NOT NULL,
  data        bytea       NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL
);

CREATE INDEX attachments_uploader_idx ON attachments (uploader_id);
CREATE INDEX attachments_expires_idx ON attachments (expires_at);
