-- New devices must be approved by an existing one (or recovered by e-mail).
--
-- A pending device can't send or receive messages and isn't listed to
-- contacts, so they never encrypt to it. Approval is an Ed25519 signature by
-- an approved device of the same account over the new device's keys (see
-- devices.js, approvalMessage), so a stolen session token is not enough.

ALTER TABLE devices ADD COLUMN approved_at timestamptz;
ALTER TABLE devices ADD COLUMN approved_by uuid REFERENCES devices (id) ON DELETE SET NULL;
ALTER TABLE devices ADD COLUMN approval_signature text;
UPDATE devices SET approved_at = created_at;

ALTER TABLE email_codes DROP CONSTRAINT email_codes_purpose;
ALTER TABLE email_codes ADD CONSTRAINT email_codes_purpose CHECK (purpose IN ('verify', 'reset', 'device'));
