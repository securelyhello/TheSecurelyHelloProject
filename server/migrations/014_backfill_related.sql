-- Backfill reports.related (013) where the relationship is still visible:
-- the reporter is still a contact, or the reported account sent them a
-- request. Blocks removed both, so older blocks can't be classified and stay
-- uncounted. Restrictions already in place simply run out (at most 7 days).
UPDATE reports r SET related = true
 WHERE EXISTS (SELECT 1 FROM contacts c WHERE c.owner_id = r.reporter_id AND c.contact_id = r.reported_id)
    OR EXISTS (SELECT 1 FROM contact_requests q WHERE q.sender_id = r.reported_id AND q.receiver_id = r.reporter_id);
