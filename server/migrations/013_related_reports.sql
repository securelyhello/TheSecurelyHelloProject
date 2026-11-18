-- Whether the reporter or blocker had dealt with the account before (a
-- contact, or the account had sent them a request), recorded when the report
-- or block is made, since blocking removes that history. Only these count
-- towards automatic restrictions, so throwaway accounts can't restrict
-- anyone (audit run 1, U3-3).
ALTER TABLE reports ADD COLUMN related boolean NOT NULL DEFAULT false;
ALTER TABLE blocks ADD COLUMN related boolean NOT NULL DEFAULT false;
