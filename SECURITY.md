# Security

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's **Report a vulnerability**
(Security tab → Advisories) for this repository, with steps to reproduce and
the version or commit. We aim to reply within 72 hours and to fix serious
issues within 30 days, and we credit reporters who want it.

## What is protected

| | Who can read it |
|---|---|
| Message text, attachments, reactions, edits, deletions, read receipts, typing | Only the people in the chat, on their approved devices |
| Attachment files on the server or your VPS | Nobody: stored encrypted; the key travels inside the encrypted message |
| Local chat database | Encrypted with a key kept in the platform keystore |
| Profile photos and "about" lines | Only your contacts and your own devices |
| Backup files | Whoever has the backup key: 125 random bits, shown once, never stored by us. XSalsa20-Poly1305, bound to your account. Sessions and identity keys are never in a backup |
| History copied to a new device | Only that device: sent as an end-to-end message to your own approved devices |
| Passwords | Hashed (scrypt) on the server |
| Two-step secrets | AES-256-GCM at rest when `TOTP_ENCRYPTION_KEY` is set |

### Cryptography

- **Sessions**: X3DH with signed and one-time prekeys, then the Double
  Ratchet (X25519, HKDF-SHA256, XSalsa20-Poly1305), per device. Headers are
  bound as associated data. Forward secrecy and post-compromise recovery come
  from the ratchet.
- **Identity**: each device has an Ed25519 signing key and an X25519
  identity key. Contacts encrypt to every approved device separately.
- **Safety numbers**: 60 digits over both people's device keys. Comparing
  them (or scanning the QR code) proves no one swapped keys. A verified
  contact's keys are pinned: if they change, the app stops sending and asks
  the user to verify again.
- **New devices** must be approved by an existing device (an Ed25519
  signature over the new device's keys), or recovered by e-mail, which signs
  out every other device and changes the safety number.
- **Transport**: TLS to the server (release builds refuse plain http),
  optional certificate pinning (`API_CERT_PINS`), DTLS for direct
  connections, with the end-to-end layer on top of both.

## What the server can see

The server relays ciphertext and can't read it. It does see metadata:

- account e-mail, username, display name;
- who is contacts with whom, and who blocked whom;
- who is in which group, and who its admins are (not the group's name,
  and nothing said in it);
- when each device connects and from which IP address;
- the size and time of each relayed message and attachment, and its sender
  and recipient devices;
- the push token of devices that turned on push (wake-ups carry no content).
- messages a user chooses to include when reporting someone (kept for a year
  for moderation, then deleted).

Relayed messages are deleted when delivered and after `RELAY_TTL_HOURS`
otherwise. Attachments expire after `ATTACHMENT_TTL_DAYS`.

## Spam and abuse

Message content is end-to-end encrypted, so spam controls never look at it:

- Signing up and asking for a reset e-mail need a solved proof-of-work
  challenge. Signups are capped per IP, and disposable e-mail domains are
  refused.
- Only contacts can message each other, and becoming contacts takes an
  accepted request. Group members can also reach each other, but only an
  admin can add people, and only their own contacts, so a stranger can't
  put you in a group. Blocking someone cuts them off in shared groups too. Requests from accounts less than a week old carry a
  warning, and accounts less than a day old have a smaller quota.
- Accounts that several people report or block, or whose requests are
  mostly rejected, can't send new requests for a while (see
  `server/DEPLOY.md`, Spam controls).
- Reports include only the messages the reporter chooses to share.

## Known limitations

- **A malicious server can add a device to an account** and claim it was
  recovered by e-mail. Contacts would then encrypt to it. Defense: verify
  safety numbers. Verified contacts are protected automatically, because
  any key change pauses sending. Unverified contacts only see a notice.
- No sealed sender: the server knows who messages whom.
- No post-quantum key agreement yet.
- Group membership is visible to the server, which needs it to let members
  who aren't contacts reach each other. The authoritative member list is
  the one members' apps agree on end to end; a server that adds someone to
  its own copy still can't get them messages, because apps only encrypt to
  members an admin added.
- Disappearing messages are removed from devices running this app. They
  can't stop a recipient taking a photo of the screen.
- The app lock protects the UI. The data is protected by the platform
  keystore and the device's own disk encryption.
- Screen security (blocking screenshots) is enforced on Android only.
  Elsewhere the app is covered in the app switcher.

## For operators

- Run behind HTTPS with HSTS. Set `TRUST_PROXY` to the number of proxies.
- Set `TOTP_ENCRYPTION_KEY` and `ADMIN_TOKEN` to long random strings and
  keep them out of the repository.
- Keep `EMAIL_VERIFICATION=required` with real SMTP.
- Optionally pin the server key in app builds (see `server/DEPLOY.md`).
- Back up Postgres. Message content isn't in it, but accounts, contacts and
  prekeys are.

## Testing

- Unit, widget and end-to-end tests run in CI on every push
  (`.github/workflows/ci.yml`).
- Fuzzing: `test/decoder_fuzz_test.dart` (wire format, ratchet headers,
  file strings, QR codes, certificates) and `server/test/fuzz.test.js`
  (every API route). Set `FUZZ_SEED` and `FUZZ_ROUNDS` to reproduce a run or
  run longer.
- `.github/workflows/security.yml` runs dependency audits, CodeQL and a
  secret scan. Dependabot keeps dependencies current.
