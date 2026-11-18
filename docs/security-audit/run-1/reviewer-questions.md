# Questions from the context-free reviewer

A small model with no briefing read the repository and asked these. Answers
and fixes are in REPORT.md.

1. devices.js DELETE /api/devices/:id has no approved-device check, and auto-approve re-runs on key change: can a pending session delete the approved devices and get itself approved with only a password?
2. devices.js: a session with no device can name any existing device id of its account and overwrite its keys. What proves it is the same install?
3. api.js sign-in: the per-e-mail limit is taken before the password check, so 10 wrong tries lock the owner out.
4. api.js lookup by username/id ignores `discoverable`. Is "discoverable" only about search?
5. api.js reset: the suspended check before the code check reveals suspended accounts.
6. twofactor.js: plaintext `p:` secrets stay readable after a key is set; nothing re-seals them; the key has no minimum length.
7. safety.js/spam.js: any account can report any user; three throwaway reporters restrict the target for 7 days.
8. safety.js: reported evidence is stored in plaintext and never deleted; SECURITY.md doesn't list it.
9. devices.js POST /api/relay: a full queue on one device throws after others were already queued. Does a retry duplicate messages?
10. chat_service.dart: the safety number shown comes from the cached device list, but markVerified pins a freshly fetched list. The pinned keys may not be the ones the user compared.
11. api.js: cancelling a request notifies the receiver even when the receiver blocked the sender, which reveals the block.
12. realtime.js says run one instance, but nothing prevents a second.
13. api.js: a rejected sender can re-send to the same person at once; should there be a cooldown?
14. attachments.js: the quota check isn't atomic; account deletion leaves blobs.
15. ratchet.dart: skipped keys over 2000 are dropped silently; is the failure surfaced, and is it tested?
