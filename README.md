# Securely Hello

Peer-to-peer, end-to-end encrypted chat built with Flutter.

**Concept:** the server is only a phonebook and a switchboard. It handles
sign-in, usernames, public keys, contact requests and the WebRTC handshake.
Messages travel directly between devices over WebRTC data channels. When the
other person is offline, the *encrypted* envelope waits in a short-lived relay
queue (24 h) and is deleted as soon as their device picks it up. Private keys
and chat history never leave the device.

## How a message travels

```
 Alice's device                      Securely Hello server                 Bob's device
 ──────────────                      ─────────────────────                 ────────────
 text ─► sign (Ed25519)
      ─► encrypt (X25519 NaCl box)
      ─► envelope ──── WebRTC data channel (direct, DTLS) ────────────► verify + decrypt
                  └─── or relay queue (ciphertext only) ──WebSocket───► verify + decrypt
                                                                          ─► receipt back
```

1. **Keys.** Each device generates an Ed25519 signing key and an X25519
   encryption key. Private halves live in the platform keystore (Android
   Keystore / iOS Keychain / DPAPI / libsecret). Only public halves are sent
   to the server.
2. **Sending.** The payload (text, receipt or typing flag, plus sender and
   recipient ids) is signed, then boxed to the recipient's public key. If a
   data channel is open it goes P2P; otherwise it goes to the relay queue
   while a P2P handshake starts in the background.
3. **Handshake.** SDP offer/answer and trickle ICE are forwarded live over
   one authenticated WebSocket and never stored. Simultaneous offers are
   resolved (the lower user id yields), early candidates are buffered, and a
   handshake times out after 30 s.
4. **Receiving.** The envelope is verified against the sender's signing key
   and decrypted. It is stored in SQLite with the body encrypted at rest under
   a per-account key, deduplicated by message id, and acknowledged with a
   *delivered* or *read* receipt.
5. **Trust.** Each chat has a 60-digit **safety number** (Contact info). If
   the two sides' numbers match, the server could not have swapped keys. When
   a contact's keys change, a notice appears in the chat.

## Project layout

```
lib/
  core/
    chat/chat_service.dart          orchestrator: send/receive, signaling, relay, receipts
    chat/wire_protocol.dart         envelope + signed payload format (v2)
    crypto/crypto_core.dart         NaCl box, Ed25519, SecretBox, safety numbers
    networking/directory_service.dart        HTTP + WebSocket client for server/
    networking/p2p_connection_manager.dart   one RTCPeerConnection + data channel per contact
    storage/local_storage.dart      per-account SQLite, bodies encrypted at rest
    storage/secure_key_store.dart   private keys, DB key and session token in the OS keystore
    providers/                      Auth / Chat / Contacts / Connection (Provider)
  features/                         auth, home, chat, contacts, settings screens
  shared/                           theme + widgets
server/                             Node.js backend (Neon Postgres + Redis); see server/DEPLOY.md
  src/mailer.js                     transactional e-mail (Resend / Brevo / dry-run log)
integration_test/                   end-to-end tests against a running server
test/                               crypto, wire-protocol and widget tests
scripts/dev.sh                      local Postgres + Redis + server
```

## Server

`server/` is a small Node.js service (dependencies: `pg`, `ioredis`, `ws`).

- **Neon Postgres** holds the durable directory: accounts (scrypt password
  hashes), hashed session tokens, public keys, contacts and contact requests.
- **Redis** holds short-lived data: presence, rate limits, caches and the 24 h
  ciphertext relay queue (native TTLs, `noeviction`).
- **WebSocket** (`/api/ws`) carries signaling, presence and pushes.
- **TURN credentials** (`GET /api/turn`, bearer) are short-lived coturn REST
  credentials (HMAC of `<expiry>:<userId>` under `TURN_SECRET`), so peers
  behind strict NAT can still connect directly through `turn.thenn.in`.
- **E-mail** (`src/mailer.js`) sends 6-digit codes for password reset and
  e-mail verification through Resend or Brevo (plain HTTPS, no SMTP).
  `EMAIL_PROVIDER` must be `resend` or `brevo` to send anything: the default,
  `log`, is a dry-run whatever else is set (a warning is logged in
  production), and outside production the code is printed to the server's
  stdout. A global daily cap (`EMAIL_DAILY_CAP`, default 90, minimum 2) keeps
  it inside free-tier quotas; verification mail stops at 2/3 of it (60 by
  default, 26 at 40) so resets keep working.

The server never sees plaintext or private keys, takes the sender's identity
from the session (never from the request), and only forwards signaling and
relay envelopes between accepted contacts. Deployment: `server/DEPLOY.md`.

### Password reset and e-mail verification

Codes are 6 digits, typed into the app (no links). Only an HMAC-SHA256 of the
code (under `CODE_HMAC_KEY`) is stored, there is one live code per account and
purpose, and a code dies after 5 wrong attempts. Reset codes last 15 min,
verification codes 30 min. While a code is live and under 60 s old, asking
again returns the same `200` without sending another mail. Changing the
password normally deletes any pending reset code.

| Endpoint | Auth | Body | Result |
|---|---|---|---|
| `POST /api/auth/request-password-reset` | none | `{email}` | `200 {"ok":true}` for any well-formed address, whether or not the account exists; `400 invalid_email` |
| `POST /api/auth/reset-password` | none | `{email, code, new_password}` | `204`; `400 invalid_code` / `weak_password` / `invalid_email` |
| `POST /api/auth/request-verification` | bearer | | `200 {"ok":true}`; `409 already_verified`; `503 unavailable` (daily cap) |
| `POST /api/auth/verify-email` | bearer | `{code}` | `200` with the updated profile; `400 invalid_code` |

All four are rate-limited (`429 rate_limited`): reset requests 3/h and 5/day
per e-mail address and 5/h and 20/day per IP (identical for known and unknown
addresses), verification requests 3/h per account. Sign-up and both reset
endpoints only accept plain ASCII addresses (no `<`, `>`, commas, quotes,
spaces or non-ASCII); sign-in still accepts any address stored earlier. A
successful reset signs out
every session and closes open WebSockets; the app returns to the login screen
with the e-mail filled in. `GET /api/me` and the sign-in/sign-up `user` object
include `email_verified`.

## Setup

1. `cp .env.example .env` and set `API_BASE_URL` to your server
   (`http://127.0.0.1:8787` for local development). TURN credentials come
   from the server (`GET /api/turn`, configured with `TURN_SECRET` and
   `TURN_URLS` in `server/.env`); the app caches them until shortly before
   they expire (`TURN_TTL_SECONDS`, default 3600; refreshed in the background
   5 min before expiry, or at half the TTL if sooner). TURN is disabled when
   `TURN_SECRET` or `TURN_URLS` is empty. `TURN_URLS`, `TURN_USERNAME` and
   `TURN_CREDENTIAL` in the root `.env` are only an optional static fallback;
   the root `.env` ships inside the app, so never put a real long-term TURN
   credential there. Without any TURN server,
   peers behind strict NAT (common on mobile data) fall back to the relay
   queue instead of connecting directly.
2. Local backend: `scripts/dev.sh` (needs Docker and Node 22+).
3. `flutter pub get`, then `flutter run`.

E-mail settings (`EMAIL_*`) and `TURN_SECRET` belong to the server only
(`server/.env`). The root `.env` is bundled into the app, so never put an API
key or secret there.

Linux desktop needs `libsecret-1-dev` (Debian/Ubuntu) or `libsecret-devel`
(Fedora). Two accounts on one machine:

```
SH_PROFILE=alice flutter run -d linux
SH_PROFILE=bob   flutter run -d linux
```

After the app-ID change (below), Linux development data moved from
`~/.local/share/com.example.securelyhello` to
`~/.local/share/securelyhello.thenn.in`. Copy the old folder across if you
want to keep a local test identity and history.

## App ID and release signing

The application ID is `securelyhello.thenn.in` on every platform (Android
`applicationId`, iOS/macOS bundle ID, Linux `APPLICATION_ID`). The Android
Kotlin package/namespace is `securelyhello.thenn`, because `in` is a Kotlin
keyword.

Android release builds are signed with an upload key described by
`android/key.properties` (git-ignored):

```
storeFile=/home/you/.keystores/securelyhello/upload-keystore.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

`storeFile` should be an absolute path. If `key.properties` exists, all four
entries are required: the Gradle build fails if any is missing or empty. Keep
the keystore outside the repository and back it up; losing it means you can no
longer publish updates under the same key. Without `key.properties`,
`flutter build apk --release` falls back to the debug key with a warning,
which is fine for local testing but not for distribution. Check with
`apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk`.

## Tests

```
flutter test                                  # crypto, wire protocol, widgets
(cd server && npm test)                       # API, WebSocket, relay queue, e-mail codes (needs scripts/dev.sh db)
flutter test integration_test/e2e_chat_test.dart -d linux   # two real clients against the running server
flutter test integration_test/ui_flow_test.dart -d linux    # drives the UI, saves screenshots (run files one at a time)
```

`integration_test/e2e_chat_test.dart` signs up two accounts, exchanges a
contact request, opens a real WebRTC data channel, checks delivered/read
receipts, then takes one side offline and checks that the relay queue holds
only ciphertext and is emptied on reconnect.

## Known limits / next steps

- **E-mail verification is soft.** Unverified accounts get a banner in
  Settings but nothing is blocked, and no e-mail is sent at sign-up. A
  successful password reset also marks the address verified.
- **The e-mail address cannot be changed** after sign-up.
- **Password reset keeps chats only on a known device.** Keys and history stay
  on the device you sign back in on. Resetting and signing in on a new device
  creates a new identity (see below), and the old history is not recoverable.
- **One active device per account.** Signing in on a new device publishes new
  keys, so contacts encrypt to the newest device. Messages relayed to the old
  keys can't be decrypted (you'll see a notice).
- **No forward secrecy yet.** Keys are static per device. The next step would
  be an X3DH + Double Ratchet session layer on top of `WireCodec`.
- **Attachments and push notifications** are not implemented. With the app
  closed, messages wait in the relay queue until it is opened.
