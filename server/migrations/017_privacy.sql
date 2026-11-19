-- 1.1: "Last seen and online" privacy. Off: nobody sees your online status
-- or last seen, and you see nobody's. Additive; on for everyone by default.
ALTER TABLE users ADD COLUMN IF NOT EXISTS show_presence boolean NOT NULL DEFAULT true;
