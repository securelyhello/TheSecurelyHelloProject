-- Group membership. Names, pictures and messages are end to end encrypted
-- between members and never stored here; this only says who may reach whom.
CREATE TABLE groups (
  id uuid PRIMARY KEY,
  created_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE group_members (
  group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  admin boolean NOT NULL DEFAULT false,
  -- Join order; the app uses the same order to pick a new admin.
  seq bigserial NOT NULL,
  PRIMARY KEY (group_id, user_id)
);
CREATE INDEX group_members_user ON group_members (user_id);
