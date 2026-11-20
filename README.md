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
- **Group chats** of up to 64 people, who don't all need to know each other.
  Each message is encrypted separately for every member's devices. Admins
  add (their own contacts), remove and promote members; every member's app
  checks each change, so a server can't rename a group or add someone to
  it unnoticed. Per-member delivered and read receipts.
- **Voice and video calls** with contacts. Call setup travels end to end
  like a message, so the server can't swap the keys that protect the media
  (DTLS-SRTP). All your devices ring; the one you answer on takes the call.
- **Profile photos and voice notes**, both sent end to end. The server
  never sees a photo, an "about" line or a recording.
- **Encrypted backup and history transfer**: save your chats to a file sealed
  with a 25-character backup key, or copy them to a device you just approved.
  The copy travels as an end-to-end message.
- **E-mail verification and password reset** with 6-digit codes.
- **Notifications** are built on the device after decryption. Optional push
  wake-ups (Firebase Cloud Messaging) never carry content.
- **Direct P2P when possible**, with a relay queue otherwise. Includes
  delivered/read receipts, typing indicators and presence.
- **Stories** (1.1): text, photo or video for 24 hours, for all contacts,
  chosen people or everyone but some. Each story has its own key, sealed to
  each viewer's devices; the server stores ciphertext only. Seen-by,
  replies and reactions.
- **Calls that keep going** (1.1, Android): a foreground service with an
  ongoing notification (mute, hang up), a full-screen incoming-call screen,
  picture-in-picture, Bluetooth and earpiece routing, proximity screen-off.
- **Notifications** (1.1): reply and mark as read from the notification,
  conversations grouped per chat, per-chat mute, sounds, and message text
  hidden unless you turn it on.
- **Organising chats** (1.1): pin, archive, mute, star, forward, drafts and
  search inside messages. A calls tab with history.
- **In-app updates** (1.1, website APK only): the app checks
  `latest.json`, downloads the APK for its CPU, and installs it only if
  the SHA-256 and the signing certificate match. Off in Play builds
  (`--dart-define=DISTRIBUTION=play`).

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
- **Several instances** can run behind a load balancer, without sticky
  sessions: they route to each other's sockets over Redis pub/sub. Optional
  Prometheus metrics (`METRICS_TOKEN`) and a coturn relay for calls, with
  short-lived credentials (`TURN_SECRET`). See `server/DEPLOY.md`.

The server never sees plaintext, file names or private keys. It takes the
sender's identity and device from the session (never from the request), and
only forwards signaling, relay envelopes and attachments between accepted
contacts. Deployment and configuration: `server/DEPLOY.md`.

## Setup

0. Run `python3 tools/fetch_fonts.py` once before building. It downloads the
   Chillax font files into `assets/fonts/` and `website/assets/fonts/`. The
   font is licensed for our app and site, but the licence forbids
   redistributing it, so the files are not in this repository.
1. `cp .env.example .env` and set `API_BASE_URL` to your server
   (`http://127.0.0.1:8787` for local development). With `API_BASE_URL`
   unset or empty, release builds use `https://api.hello.thenn.in` and
   debug builds the local dev server. The `FIREBASE_*` values enable push
   wake-ups on Android and iOS (see `server/DEPLOY.md`, Push wake-ups).
   **`.env` ships inside the app** (it is a Flutter asset), so never put
   long-lived secrets in it. For calls behind strict NAT (common on mobile
   data), set `TURN_SECRET` on the server, which hands out short-lived
   credentials, instead of `TURN_USERNAME`/`TURN_CREDENTIAL` here.
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

## App ID and release builds

The app ID is `securelyhello.thenn.in` on every platform: Android
`applicationId`, iOS and macOS `PRODUCT_BUNDLE_IDENTIFIER` (tests:
`securelyhello.thenn.in.RunnerTests`), Linux `APPLICATION_ID`. The Android
`namespace` and Kotlin package are `securelyhello.thenn`, because `in` is a
Kotlin keyword.

Minimums: Android minSdk 24, targetSdk 36, compileSdk 37 (AGP 9.1.1,
Gradle 9.3.1); iOS 15.0; macOS 11.0.

### Android signing

Release builds are signed with the key named in `android/key.properties`
(git-ignored):

```
storeFile=/absolute/path/outside/the/repo/upload-keystore.jks
storePassword=...
keyAlias=...
keyPassword=...
```

- Keep the keystore **outside the repository**, and back it and its
  passwords up somewhere safe. Use **Play App Signing**, so the key in
  `key.properties` is only the upload key, and Google can reset it if it is
  lost.
- If `key.properties` exists, all four values are required; the build fails
  otherwise.
- Without `key.properties`, release builds **fail** rather than ship a
  debug-signed app. For a local test build only (Play won't accept it), pass
  `--android-project-arg=allowDebugSignedRelease=true`
  (`./gradlew assembleRelease -PallowDebugSignedRelease=true` with Gradle).

```
flutter build apk --release          # APK
flutter build appbundle --release    # AAB for Play
```

### iOS

- The Push Notifications capability is on (`ios/Runner/Runner.entitlements`,
  `aps-environment`); the App ID in the Apple Developer account needs it too.
  The file says `development` on purpose, so debug builds get APNs tokens
  from the sandbox; Xcode rewrites it to `production` when you export or
  upload an App Store / TestFlight build. Don't change it to `production`
  by hand.
- Background modes: `remote-notification` and `audio`. The `voip` mode was
  removed (there is no PushKit / CallKit integration).
- TODO (owner): decide `ITSAppUsesNonExemptEncryption` in `Info.plist` and
  the export-compliance answer before submitting. The app uses end-to-end
  encryption, so it is not set yet.

### Hardening in release builds

- `debugPrint` is silenced, so nothing reaches logcat, Console or journald.
- 2FA secrets, recovery codes and backup keys copied to the clipboard are
  cleared after 60 s (unless something else was copied since).
- File names of incoming attachments are sanitised before they are shown or
  saved.
- Android: no cloud backup and no device-to-device transfer of app data
  (`allowBackup="false"` and `data_extraction_rules.xml`); keys and the
  message database stay on the device. Cleartext HTTP is allowed only in
  debug builds, for the local dev server.
- Server side: deleting the account and changing the username need the
  current password again (and a 2FA code when two-step verification is on);
  ended sessions and suspended accounts are rejected at once, even from the
  session cache; a push token signed in on another account is refused
  (`409 push_token_in_use`); one contact can take only a few of another's
  one-time prekeys (10 a minute, 100 a day), after which bundles carry just
  the signed prekey.

## Website

`website/` is the product page and the invite landing page (`/i/<token>`):
static files that load nothing from other hosts. Its screenshots and test
results come from the real test runs. See [website/README.md](website/README.md).
It is served at `https://securelyhello.thenn.in`. The privacy and terms
pages are built from `docs/legal/` by `tools/build_site.py`;
`website/config.js` holds the download links and the APK certificate
fingerprint. Releases: `tools/release_apk.py` writes the APKs and
`latest.json` into `website/download/` (git-ignored). App icons come from
`assets/brand/` via `tools/make_icons.py`; see [docs/BRAND.md](docs/BRAND.md).

## Languages

English and Hindi, chosen in Settings > Appearance > Language (default: the
system's). Strings live in `lib/l10n/app_<code>.arb`; `flutter gen-l10n`
(run automatically by `flutter pub get`/builds) generates `L10n`. To add a
language, copy `app_en.arb` to `app_<code>.arb`, translate it, and add the
name to `LocaleController.names`; `test/l10n_test.dart` checks every
string and placeholder is there.

Translated so far: welcome, log-in, sign-up, the main tabs, chat and
contact lists, the message composer, the lock screen and the settings
sections. Other screens are still English; move their strings into the
`.arb` files as they are touched.

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

See also [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) (open issues, and what
1.1 left out) and [docs/RELEASE_NOTES_1.1.md](docs/RELEASE_NOTES_1.1.md).

- **Older history reaches a new device only when you send it.** After you
  approve a device, the app offers to copy your chats to it; otherwise it
  receives messages from the moment it is linked. Disappearing and deleted
  messages are never copied or backed up.
- **Losing the app data makes a new device.** The device id lives in the
  local database. A reinstall registers as a new device, and the old one
  stays listed (and queues messages for 24 h) until you remove it under
  Linked devices.
- **Push is off until a Firebase project exists** (`FIREBASE_*` in `.env`,
  `FCM_SERVICE_ACCOUNT` on the server, APNs key uploaded to Firebase for
  iOS, then a rebuild; see `server/DEPLOY.md`). Without it, mobile messages
  wait in the relay queue until the app is opened. Desktop apps receive
  them while running.
- **E-mail is capped** at `EMAIL_DAILY_CAP` (default 40) messages in any
  24 h. Past the cap, new sign-ups get no verification mail until it frees
  up, and device recovery by e-mail is temporarily unavailable.
- **Push timing is visible to Google/Apple**: a wake-up reveals that
  *something* arrived for a device, though not what or from whom.
- **Groups send one copy per member.** Fine up to the 64-member cap, but each
  message costs one relay call per member. New members see messages from
  when they joined, not earlier ones.
- **Calls are 1:1.** On Android a running call is kept alive by a
  foreground service, and an incoming call rings full-screen even with the
  app closed, but only once push is set up (the app must be woken). There's
  no CallKit on iOS. A call offer older than a minute is recorded as missed
  rather than ringing. Behind strict NATs, calls need a TURN server
  (`TURN_URLS`, see Setup).
