-- Securely Hello: initial schema.
--
-- The server is a phonebook and a switchboard. Postgres (Neon) holds only the
-- durable directory; nothing here ever holds a message or a private key:
--   * users           public profile + public keys + password hash (scrypt)
--   * sessions        SHA-256 hashes of opaque bearer tokens
--   * contact_requests / contacts   the social graph
-- Short-lived data lives in Redis instead: presence / last seen, rate-limit
-- counters, caches, and the 24 h ciphertext relay queue (native TTLs).
-- WebRTC signaling (SDP / ICE) is forwarded in memory and never stored.
--
-- gen_random_uuid() is built into PostgreSQL 13+ (Neon runs 15+).

CREATE TABLE users (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  email                 text        NOT NULL,
  username              text        NOT NULL,
  display_name          text        NOT NULL DEFAULT '',
  password_hash         text        NOT NULL,
  signing_public_key    text        NOT NULL,
  encryption_public_key text        NOT NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT users_username_format CHECK (username ~ '^[a-z0-9_]{3,30}$'),
  CONSTRAINT users_email_length CHECK (char_length(email) BETWEEN 3 AND 254),
  CONSTRAINT users_display_name_length CHECK (char_length(display_name) <= 64)
);

CREATE UNIQUE INDEX users_email_key ON users (lower(email));
CREATE UNIQUE INDEX users_username_key ON users (username);

CREATE TABLE sessions (
  token_hash   bytea       PRIMARY KEY,
  user_id      uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL
);

CREATE INDEX sessions_user_idx ON sessions (user_id);
CREATE INDEX sessions_expires_idx ON sessions (expires_at);

CREATE TABLE contact_requests (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id   uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  receiver_id uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  status      text        NOT NULL DEFAULT 'pending',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contact_requests_status CHECK (status IN ('pending', 'accepted', 'rejected')),
  CONSTRAINT contact_requests_not_self CHECK (sender_id <> receiver_id),
  CONSTRAINT contact_requests_pair UNIQUE (sender_id, receiver_id)
);

CREATE INDEX contact_requests_receiver_idx ON contact_requests (receiver_id, status);

-- One row per direction; a pair is "contacts" when both rows exist.
CREATE TABLE contacts (
  owner_id   uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  contact_id uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  nickname   text,
  added_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_id, contact_id),
  CONSTRAINT contacts_not_self CHECK (owner_id <> contact_id),
  CONSTRAINT contacts_nickname_length CHECK (nickname IS NULL OR char_length(nickname) <= 64)
);

CREATE INDEX contacts_contact_idx ON contacts (contact_id);
