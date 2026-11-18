# Securely Hello

Peer-to-peer, end-to-end encrypted chat built with Flutter.

**Concept:** the server is only a phonebook and a switchboard. It handles
sign-in, usernames, the public keys of each device, contact requests and the
WebRTC handshake. Messages travel directly between devices over WebRTC data
channels. When a device is offline, its *encrypted* envelope waits in a
short-lived relay queue (24 h) and is deleted as soon as that device picks it
up. Private keys and chat history never leave the device.

## Features

- **End-to-end encryption with forward secrecy**: X3DH key agreement and a
  Double Ratchet session per pair of devices. Keys change with every
  message, so a key stolen today can't decrypt earlier messages.
- **Several devices per account**: each phone or computer has its own keys.
  A message reaches all of the recipient's devices, and a copy goes to your
  own other devices. Read state syncs between your devices too. Settings →
  Linked devices lists and removes them.
- **Safety numbers** cover every device of both people and change when
  either adds a device. A notice appears in the chat when that happens.
- **Encrypted attachments**: photos and files are encrypted on the device
  with a fresh key, and only the ciphertext is uploaded. Photos show inline;
  files can be saved.
- **E-mail verification and password reset** with 6-digit codes.
- **Notifications** are built on the device after decryption. Optional push
  wake-ups (Firebase Cloud Messaging) never carry content.
- **Direct P2P when possible**, with a relay queue otherwise. Includes
  delivered/read receipts, typing indicators and presence.

## How a message travels

```
 Alice's phone                     Securely Hello server               Bob's laptop / Bob's phone
 ─────────────                     ─────────────────────               ──────────────────────────
 text ─► for each of Bob's devices (and Alice's other devices):
         Double Ratchet encrypt
      ─► envelope {to: device} ─── WebRTC data channel (direct, DTLS) ─► ratchet decrypt
                               └── or that device's relay queue ──WS──► ratchet decrypt
                                                                         ─► receipt back
```

1. **Devices and keys.** Each install generates an Ed25519 signing key and
   an X25519 identity key, kept in the platform keystore (Android Keystore,
   iOS Keychain, DPAPI, libsecret). It registers the public halves with the
   server, along with a signed prekey and 100 one-time prekeys. The private
   prekeys stay in the local database, which is encrypted at rest. The
   signed prekey rotates weekly, and one-time prekeys are topped up when the
   server reports it is running low.
2. **Sessions.** To reach a device for the first time, the sender claims its
   prekey bundle (each one-time prekey is handed out once, and only to
   contacts) and runs X3DH. Both sides then run the Double Ratchet:
   HKDF/HMAC-SHA256, X25519 and XSalsa20-Poly1305. The header and both
   identities are bound into every message. When both sides start a session
   at the same moment, the session record resolves it.
3. **Sending.** A message is encrypted once per recipient device, plus a
   `sync` copy for each of the sender's other devices. Each envelope goes
   over that device's data channel if one is open, otherwise into that
   device's relay queue. The sender lists every device it knows of the
   recipient, and the server refuses a stale list (409), so no device is
   silently skipped.
4. **Handshake.** SDP offer/answer and trickle ICE are forwarded live, per
   device, over one authenticated WebSocket, and never stored.
5. **Receiving.** The envelope is decrypted with the session for
   `(sender, sender device)`. Redeliveries are recognised by their envelope
   id, and messages by their message id. Bodies are stored encrypted at
   rest. The device acknowledges each message as *delivered* or *read*.
6. **Trust.** Each chat shows a 60-digit **safety number** (Contact info)
   computed over all devices of both people. If both sides see the same
   number, the server could not have slipped in a key.

## Project layout

```
lib/
  core/
    chat/chat_service.dart          orchestrator: per-device fan-out, sync, relay, receipts, P2P
    chat/wire_protocol.dart         envelope (v3) + payload format
    chat/attachment_service.dart    encrypt / upload / verify / decrypt attachments
    crypto/ratchet.dart             X3DH, Double Ratchet, session records
    crypto/session_manager.dart     sessions per remote device, device lists, identity checks
    crypto/device_manager.dart      device registration, prekeys, signed-prekey rotation
    crypto/crypto_core.dart         NaCl primitives, safety numbers
    networking/directory_service.dart        HTTP + WebSocket client for server/
    networking/p2p_connection_manager.dart   one RTCPeerConnection per remote device
    notifications/                  local notifications, optional FCM wake-ups
    storage/local_storage.dart      per-account SQLite, encrypted at rest
    storage/secure_key_store.dart   device keys, DB key and session token in the OS keystore
    providers/                      Auth / Chat / Contacts / Connection (Provider)
  features/                         auth, home, chat, contacts, settings screens
  shared/                           theme + widgets
server/                             Node.js backend (Neon Postgres + Redis); see server/DEPLOY.md
integration_test/                   end-to-end tests against a running server
test/                               ratchet, sessions, attachments, wire format, widgets
scripts/dev.sh                      local Postgres + Redis + server
```

## Server

`server/` is a small Node.js service (dependencies: `pg`, `ioredis`, `ws`,
`nodemailer`).

- **Neon Postgres** holds the durable directory: accounts (scrypt password
  hashes), hashed session tokens, devices with their public keys and
  prekeys, contacts and contact requests, hashed e-mail codes, and
  attachment ciphertext.
- **Redis** holds short-lived data: presence, rate limits, caches, push
  throttles and the per-device 24 h ciphertext relay queues (native TTLs,
  `noeviction`).
- **WebSocket** (`/api/ws`) carries signaling, presence and pushes.

The server never sees plaintext, file names or private keys. It takes the
sender's identity and device from the session (never from the request), and
only forwards signaling, relay envelopes and attachments between accepted
contacts. Deployment and configuration: `server/DEPLOY.md`.

## Setup

1. `cp .env.example .env` and set `API_BASE_URL` to your server
   (`http://127.0.0.1:8787` for local development). Optionally set
   `TURN_URLS`, `TURN_USERNAME` and `TURN_CREDENTIAL`. Without a TURN server,
   peers behind strict NAT (common on mobile data) fall back to the relay
   queue instead of connecting directly. The `FIREBASE_*` values enable push
   wake-ups on Android and iOS (see `server/DEPLOY.md`).
2. Local backend: `scripts/dev.sh` (needs Docker and Node 22+). In
   development, verification and reset codes are printed to the server's
   stderr.
3. `flutter pub get`, then `flutter run`.

Linux desktop needs `libsecret-1-dev` and, for voice notes,
`libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-good`
(Debian/Ubuntu; `libsecret-devel` and `gstreamer1-devel gstreamer1-plugins-base-devel`
on Fedora); the file picker uses the XDG desktop portal
(`xdg-desktop-portal`, present on standard GNOME/KDE desktops). Two
accounts, or two devices of one account, on one machine:

```
SH_PROFILE=alice flutter run -d linux
SH_PROFILE=bob   flutter run -d linux
```

## Website

`website/` is the product page and the invite landing page (`/i/<token>`):
static files that load nothing from other hosts. Its screenshots and test
results come from the real test runs. See [website/README.md](website/README.md).

## Security

See [SECURITY.md](SECURITY.md) for the threat model, what the server can
see, known limitations and how to report a vulnerability.

## Tests

```
flutter test                                  # ratchet, sessions, attachments, wire format, widgets
(cd server && npm test)                       # API, devices, relay, e-mail codes, push, attachments (needs scripts/dev.sh db)
flutter test integration_test/e2e_chat_test.dart -d linux   # real clients against the running server
flutter test integration_test/ui_flow_test.dart -d linux    # drives the UI, saves screenshots (run files one at a time)
```

`flutter test` needs a `.env` file (it is bundled as an asset), so run
`cp .env.example .env` first on a fresh clone. Both integration tests read
the codes the server e-mails, so start the server with
`MAIL_TRANSPORT=file MAIL_FILE_DIR=/tmp/sh_mail` (or pass
`--dart-define=MAIL_DIR=<dir>`).

On a headless Linux machine (CI, containers) run the integration tests under
`xvfb-run -a dbus-run-session -- …` and provide an audio device: libwebrtc
aborts at the first peer connection if it cannot open one
(`Check failed: 0 == adm->Init()`). A PulseAudio null sink is enough:
`pulseaudio -D --exit-idle-time=-1 && pactl load-module module-null-sink`.
`.github/workflows/ci.yml` runs all four suites this way on every push.

`integration_test/e2e_chat_test.dart` signs up two accounts and exchanges a
contact request. It then opens real WebRTC data channels, checks receipts,
and sends an encrypted attachment. It takes one side offline to check that
the relay queue holds only ciphertext and is emptied on reconnect. Finally,
it signs Alice in on a second device and checks fan-out, sync of sent
messages and read state, matching safety numbers on all three devices, and
unlinking.

## Known limits

- **Local history is not end-to-end synced.** A newly linked device receives
  messages from the moment it is linked; older history stays on the devices
  that had it. Forward secrecy protects messages in transit; history at rest
  is protected by the device's encrypted database and keystore.
- **Losing the app data makes a new device.** The device id lives in the
  local database. A reinstall registers as a new device, and the old one
  stays listed (and queues messages for 24 h) until you remove it under
  Linked devices.
- **Push needs your own Firebase project** (`FIREBASE_*` in `.env`,
  `FCM_SERVICE_ACCOUNT` on the server, APNs set up in Firebase for iOS).
  Without it, mobile messages wait in the relay queue until the app is
  opened. Desktop apps receive them while running.
- **Push timing is visible to Google/Apple**: a wake-up reveals that
  *something* arrived for a device, though not what or from whom.
- **No group chats, voice or video calls yet.**
