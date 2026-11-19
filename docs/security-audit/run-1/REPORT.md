# Security audit, run 1

| | |
|---|---|
| Method | Cloudflare security-audit skill, quick profile, plus a context-free reviewer |
| Source | commit 08ba681 (before fixes); fixes in e8449b3, 0032f89, 883252e, e57c244, bba06f0 |
| Scope | `server/src`, `server/migrations`, `lib/`, Android and iOS config |
| Coverage | 5 units ([coverage-ledger.json](coverage-ledger.json)), map in [architecture.md](architecture.md) |
| Agents | 5 hunters, 4 verifiers (each verifier fresh for its units), 1 context-free reviewer |
| Sandbox | Reproductions ran only against a local throwaway Postgres/Redis test database and in-memory app tests. No deployed systems, no external network |
| Result | 18 unique candidates, all **confirmed** by reproduction, all **fixed** with a regression test that fails on the old code |

## Deviations from the skill

- Verifiers were one fresh agent per unit, not one per candidate, to fit the
  budget. No verifier had hunted the candidates it judged.
- Artifacts are in the repository (`docs/security-audit/run-1/`) instead of
  outside it, so the owner can read them.
- The skill's JSON validators were not run; findings use the same fields
  (verdict, severity, evidence, trace, fix).
- Phase 5 (a second independent re-verification of each record) was replaced
  by regression tests: each fix has a test that reproduces the verifier's
  scenario, fails on the old code and passes on the new one.

## Confirmed findings

| ID | Severity | Finding | Fix |
|---|---|---|---|
| U2-1 | high | A session with only the password could claim an account's existing device id with new keys and get it auto-approved, bypassing device approval | Proof of possession by the device's current key; only an account's first device ever is auto-approved; deleting devices needs an approved one |
| U5-1 | high | Wiping after 10 wrong PINs turned the lock off before deleting data, and waited on the network; killing the app mid-wipe left it unlocked with data intact | Stay locked; delete local data first; persist the intent and finish an interrupted wipe at start |
| U5-3 | high | Under the lock screen the app stayed in the accessibility tree and keyboard focus: a screen reader could read chats and press buttons | Exclude semantics, focus and pointer input while locked or covered |
| U1-1 | medium | New recovery codes could be minted with only the password, making it equal to the second factor | Needs a current authenticator or recovery code |
| U2-2 | medium | One account could fill Redis through self-relay (no byte budget), stopping the whole service | Atomic per-device (16 MB) and per-sender (32 MB) budgets for undelivered data; acks return bytes; no duplicate devices per request |
| U3-1 | medium | Unverified accounts could make a squatted e-mail address findable, appearing under the real owner's name in others' suggestions | Only verified addresses can be made findable or matched |
| U4-1 | medium | A malicious relay could replay a first message after forcing a session reset; without a one-time prekey it decrypted again, restoring deleted or expired messages and rolling back edits | A base key starts a session once, ever |
| U4-2 | medium | Marking a contact verified pinned the keys fetched at tap time, not the keys behind the number the user compared | Verification requires the fresh keys to give the compared number |
| U5-2 | medium | PIN back-off reset on app restart | Deadline persisted |
| U1-2 | low | Password change and sign-out left the ended sessions' WebSockets open | Their sockets are closed |
| U1-3 | low | Reset revealed suspended accounts before checking the code; forgot's timing depended on whether the address exists | Suspension checked after the code; mail not awaited |
| U3-2 | low | With verification required, unverified accounts could still reach people through invite links | Verification checked for the inviter |
| U3-3 | low | Three throwaway accounts could restrict any user for a week by reporting them | Only reporters and blockers who dealt with the account count |
| U3-4 | low | Deleting an account left its attachment files on disk or S3 | Deleted with the account |
| U4-3 | low | The 24 h edit window used sender-chosen timestamps | Timestamps clamped to the delivery window |
| U4-4 | low | A contact reusing an attachment id could swap or evict our cached copy | Cache keyed by id and content digest |
| U4-5 | low | Text starting with `enc1:` was stored unsealed | Always sealed |
| U5-4 | low | Contact names showed in notifications with previews off | Hidden |

U2-3 duplicated U1-2. Candidate details: `candidates-U*.json`; verdicts and
reproduction evidence: [verdicts.json](verdicts.json), [verdicts-U3.json](verdicts-U3.json).
Regression tests: `server/test/audit.test.js`, `server/test/approval.test.js`,
`server/test/relay.test.js`, `server/test/spam.test.js`, `test/app_lock_test.dart`,
`test/audit_app_test.dart`, `test/session_manager_test.dart`,
`test/attachment_service_test.dart`, and the e2e test (verification flow).

## Context-free reviewer

A small model with no briefing asked 15 questions
([reviewer-questions.md](reviewer-questions.md)). Its first question found
U2-1 independently. Fixed because of its questions: sign-in lockout of the
real owner (Q3), legacy plaintext TOTP secrets and short keys (Q6), report
retention (Q8), cancelled requests revealing a block (Q11), a second server
instance (Q12, now logged), a cooldown after rejection (Q13), and the
upload quota race (Q14). Answered as intended: exact-username lookup (Q4),
retry after a partial relay failure (Q9, deduplicated), and the skipped-key
bound (Q15).

### Follow-up round

The reviewer accepted the fixes for Q1, Q2, Q3, Q6, Q10, Q11, Q13 and Q14, and
raised two more:

- A: the per-address sign-in cap counted every attempt, so attackers on many
  IPs could still lock the owner out. It now counts only wrong passwords, and
  checking it uses nothing (`authFailures`, test in `server/test/audit.test.js`).
- B: the new `related` flag had no backfill. Migration 014 sets it where the
  relationship is still visible. Older blocks can't be classified (blocking
  removed the history), so they stay uncounted, and existing restrictions run
  out within 7 days.

## Hardening notes (not vulnerabilities, not fixed in this run)

As recorded at the end of run 1; items marked **Fixed** were fixed afterwards
(see "Fixed after run 1" below).

- **Open (by design).** The verification guard protects sending only.
  Messages from a verified contact's new, unverified device are still shown,
  marked by the safety-number notice. Hiding them would hide a real person's
  new phone. The user decides after comparing numbers.
- **Fixed in 1.1.** The app doesn't check device-approval signatures itself,
  so a malicious server can add a device to your own account. Copies of what
  you send then reach it.
- **Fixed in 1.1.** Typing indicators and direct-connection setup don't go
  through the verification guard.
- **Fixed in 1.1.** Quoted replies show what the sender claims was quoted.
- **Fixed.** Incoming attachment names aren't sanitized before the save dialog.
- **Fixed.** The session cache can keep a revoked token for up to 5 minutes in a narrow
  race. `authenticate` doesn't check suspension.
- **Fixed.** Deleting the account or changing the username needs only a session
  (no re-entry of the password).
- **Fixed.** Release builds write device addresses to the system log (`debugPrint`).
  The clipboard keeps copied 2FA secrets and recovery codes.
- **Fixed.** Contacts can drain each other's one-time prekeys at 60 claims per minute.
- **Fixed.** The `127.` loopback check matches host names starting with `127.`.
  The address comes from build config.

### Fixed after run 1

Fixed on branch `cloud-integration` after this audit; not re-audited yet.

- Attachment names: `AttachmentService.safeFileName` sanitises the
  sender-chosen name (length and byte caps, fallback `attachment`) before
  any display or save.
- Session cache: revoking sessions stamps a per-user revocation time in
  Redis, and cache entries looked up before it are ignored and never
  re-written, so a revoked token stops working at once. Suspension is
  checked in `authenticate` (Postgres) and by a Redis flag on cached
  sessions.
- Account deletion (`DELETE /api/me`) and username changes (`PATCH /api/me`)
  need `current_password`, plus `otp` when two-step verification is on.
- Release builds turn `debugPrint` into a no-op. 2FA secrets, recovery
  codes and backup keys copied to the clipboard are cleared after 60 s if
  the clipboard still holds them.
- One-time prekeys: per requester and target, at most 10 claims a minute and
  100 a day spend one-time prekeys; past that the bundle carries only the
  signed prekey (own devices are exempt).
- Loopback check: only `localhost`, literal 127.0.0.0/8 and `::1` count.
- Also: registering a push token that a signed-in device of another account
  holds answers `409 push_token_in_use` instead of taking it over; the admin
  token comparison can't throw on odd lengths; Android data extraction rules
  exclude all app data from cloud backup and device-to-device transfer; the
  release network security config no longer allows cleartext to local
  hosts (debug builds only).

### Fixed in 1.1

Not re-audited yet.

- Own devices: the server now lists `approved_by` and `approval_signature`
  for your own devices. The app (`lib/core/crypto/own_device_trust.dart`)
  trusts the devices it sees on 1.1's first run. After that it trusts a new
  device only when a trusted device's Ed25519 signature over the approval
  message checks out (chains included). A device the server merely lists
  gets no copies of what you send until you confirm it in Linked devices,
  after comparing its code. Tests: `test/own_device_trust_test.dart`.
- Typing indicators and direct (WebRTC) connections to a verified contact
  whose keys have changed are not sent or set up. This is the same guard as
  for messages.
- A quoted reply shows this device's own copy of the quoted message when it
  has one, and the sender's preview only otherwise.

## Final state

130 server tests, 107 app tests, 3 end-to-end runs and the UI walkthrough
pass on the fixed code. Server fuzzing (every route, several seeds) found no
500s.
