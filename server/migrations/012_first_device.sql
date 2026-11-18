-- When the account registered its first device. Only that very first device
-- is approved on its own; after it, removing devices can never make a new one
-- "first" again (audit run 1, U2-1).
ALTER TABLE users ADD COLUMN first_device_at timestamptz;
UPDATE users u SET first_device_at = (SELECT min(created_at) FROM devices d WHERE d.user_id = u.id);
