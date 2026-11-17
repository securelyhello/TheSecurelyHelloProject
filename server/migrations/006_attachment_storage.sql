-- Attachment bytes can live outside Postgres (filesystem on the VPS, or
-- S3-compatible storage); the row then only holds metadata.
ALTER TABLE attachments ALTER COLUMN data DROP NOT NULL;
ALTER TABLE attachments ADD COLUMN storage text NOT NULL DEFAULT 'postgres';
