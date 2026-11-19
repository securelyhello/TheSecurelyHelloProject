-- 1.1: changing your e-mail. The new address waits in pending_email until
-- the code sent to it is entered. Additive: a new code purpose and column.
ALTER TABLE users ADD COLUMN IF NOT EXISTS pending_email text;
ALTER TABLE email_codes DROP CONSTRAINT IF EXISTS email_codes_purpose;
ALTER TABLE email_codes ADD CONSTRAINT email_codes_purpose CHECK (purpose IN ('verify', 'reset', 'device', 'email'));
