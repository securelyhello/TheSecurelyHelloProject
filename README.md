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

The server never sees plaintext or private keys, takes the sender's identity
from the session (never from the request), and only forwards signaling and
relay envelopes between accepted contacts. Deployment: `server/DEPLOY.md`.

## Setup

1. `cp .env.example .env` and set `API_BASE_URL` to your server
   (`http://127.0.0.1:8787` for local development). Optionally set
   `TURN_URLS`, `TURN_USERNAME` and `TURN_CREDENTIAL`. Without a TURN server,
   peers behind strict NAT (common on mobile data) fall back to the relay
   queue instead of connecting directly.
2. Local backend: `scripts/dev.sh` (needs Docker and Node 22+).
3. `flutter pub get`, then `flutter run`.

Linux desktop needs `libsecret-1-dev` (Debian/Ubuntu) or `libsecret-devel`
(Fedora). Two accounts on one machine:

```
SH_PROFILE=alice flutter run -d linux
SH_PROFILE=bob   flutter run -d linux
```

## Tests

```
flutter test                                  # crypto, wire protocol, widgets
(cd server && npm test)                       # API, WebSocket, relay queue (needs scripts/dev.sh db)
flutter test integration_test/e2e_chat_test.dart -d linux   # two real clients against the running server
flutter test integration_test/ui_flow_test.dart -d linux    # drives the UI, saves screenshots (run files one at a time)
```

`integration_test/e2e_chat_test.dart` signs up two accounts, exchanges a
contact request, opens a real WebRTC data channel, checks delivered/read
receipts, then takes one side offline and checks that the relay queue holds
only ciphertext and is emptied on reconnect.

## Known limits / next steps

- **No e-mail verification or password reset yet.** Sign-up is e-mail +
  password + username; a forgotten password cannot be recovered.
- **One active device per account.** Signing in on a new device publishes new
  keys, so contacts encrypt to the newest device. Messages relayed to the old
  keys can't be decrypted (you'll see a notice).
- **No forward secrecy yet.** Keys are static per device. The next step would
  be an X3DH + Double Ratchet session layer on top of `WireCodec`.
- **Attachments and push notifications** are not implemented. With the app
  closed, messages wait in the relay queue until it is opened.
