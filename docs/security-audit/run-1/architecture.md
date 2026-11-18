# Architecture (audit run 1, commit 08ba681)

## Components

- **Server** (`server/src`, Node 22, ~4.6k lines): HTTP API and WebSocket on one
  port, Postgres for durable state, Redis for rate limits, the relay queue,
  presence, sessions cache and proof-of-work challenges.
  - `app.js`: request dispatch, auth (bearer session token), JSON body, NUL guard.
  - `api.js`: signup/signin/reset, profile, search, contact requests.
  - `devices.js`: device registration, approval (Ed25519 signature), e-mail
    recovery, prekeys and bundles.
  - `realtime.js`: WebSocket hub, signaling, presence.
  - `relay` routes (in `devices.js`/`api.js`): per-device encrypted envelope queue.
  - `attachments.js`, `blobstore.js`: ciphertext blobs (postgres, filesystem, S3).
  - `safety.js`: blocks, reports, admin API (ADMIN_TOKEN).
  - `twofactor.js`, `spam.js`, `invites.js`, `codes.js`, `mail.js`, `push.js`.
- **App** (`lib/`, Flutter, ~21.7k lines):
  - `core/crypto`: X3DH + Double Ratchet (`ratchet.dart`), sessions per device
    (`session_manager.dart`), device registration (`device_manager.dart`).
  - `core/chat`: wire format, chat service (send/receive, sync, actions,
    verification guard), attachments, FTS1 file strings.
  - `core/networking`: REST + WebSocket client, TLS pinning, WebRTC P2P.
  - `core/storage`: encrypted SQLite (key in platform keystore).
  - `core/security`: app lock (PBKDF2 PIN), proof of work.
  - `core/invites`: invite links, e-mail hashing for discovery.

## Trust boundaries

1. Internet → server API/WebSocket (unauthenticated: signup, signin, reset,
   challenge, username availability, health; everything else needs a session).
2. Server → app: the server is not trusted with content. It is trusted for
   routing and for the device list, mitigated by safety numbers and pinned
   verification.
3. Contact → app: decrypted payloads from another user (edits, deletes,
   reactions, attachments, sync from own devices).
4. Links/QR/clipboard → app: invite tokens, verification codes.
5. Operator → server: ADMIN_TOKEN routes.

## Assets

Account takeover (session tokens, passwords, 2FA, recovery), message
confidentiality and integrity, device list integrity, private keys on the
device, metadata (contacts, blocks, e-mail addresses), service availability.
