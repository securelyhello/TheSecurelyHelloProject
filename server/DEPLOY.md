# Deploying the Securely Hello server

One Node.js container plus its own Redis, behind a TLS-terminating reverse
proxy. Postgres is Neon (remote). Written for Coolify + Traefik, but any Docker
host works.

## What runs

| Piece | Where | Holds |
|---|---|---|
| `app` (this folder's `Dockerfile`) | container, port 8787, non-root | nothing; stateless |
| `redis` (in `docker-compose.yml`) | container, named volume, not exposed | presence, rate limits, caches, the 24 h **ciphertext** relay queue |
| Postgres | Neon | accounts, password hashes, session-token hashes, public keys, contacts |

`app` can run as several instances behind the proxy (see Several instances).

## Coolify

1. New resource → Docker Compose → this repository, base directory `/server`,
   compose file `docker-compose.yml`.
2. Attach the domain (e.g. `https://api.hello.thenn.in`) to service `app`,
   port `8787`. Do not publish host ports.
3. Environment variables:

   | Name | Required | Value |
   |---|---|---|
   | `DATABASE_URL` | yes | Neon **pooled** connection string (`...-pooler...neon.tech/neondb?sslmode=require`) |
   | `MIGRATION_DATABASE_URL` | no | Neon direct (non-pooled) string; migrations fall back to `DATABASE_URL` |
   | `TRUST_PROXY` | no | proxy hops that set `X-Forwarded-For`; default `1` (Traefik) |
   | `MIGRATE_ON_START` | no | default `1`: pending migrations are applied at boot under an advisory lock |
   | `LOG_LEVEL` | no | `info` (default), `debug`, `warn`, `error` |
   | `SMTP_URL` | recommended | e.g. `smtps://user:pass@smtp.example.com:465`; sends verification and password-reset codes |
   | `MAIL_FROM` | with SMTP | sender address, e.g. `Securely Hello <no-reply@example.com>` |
   | `EMAIL_VERIFICATION` | no | `required` (default with SMTP) or `optional` |
   | `EMAIL_DAILY_CAP` | no | most e-mails sent in any 24 h, all kinds together; default `40`, minimum `2` (see E-mail) |
   | `ADMIN_TOKEN` | no | at least 32 random characters; enables `/api/admin/*` (reports, suspensions) |
   | `TOTP_ENCRYPTION_KEY` | recommended | long random string (at least 32 characters; the server refuses shorter); encrypts two-step verification secrets at rest. Keep it with your backups: changing or losing it locks out users who use two-step verification |
   | `INVITE_BASE_URL` | recommended | invite link prefix: the website's invite page, `https://securelyhello.thenn.in/i/` in production; default `securelyhello://invite/` |
   | `POW_BITS` | no | proof-of-work difficulty for signup and reset e-mails; default `18` (about a second on a phone), `0` turns it off |
   | `BLOCK_DISPOSABLE_EMAIL` | no | `0` allows throwaway e-mail domains at signup (refused by default) |
   | `DISPOSABLE_DOMAINS_FILE` | no | extra domains to refuse, one per line |
   | `FCM_SERVICE_ACCOUNT` | no | Firebase service-account JSON (inline or base64) for push wake-ups |
   | `ATTACHMENT_MAX_MB` / `ATTACHMENT_TTL_DAYS` / `ATTACHMENT_QUOTA_MB` | no | `16` / `30` / `512` |
   | `METRICS_TOKEN` | no | 32+ random characters; enables `GET /metrics` (see Metrics) |
   | `TURN_URLS` / `TURN_SECRET` / `TURN_TTL_HOURS` | no | TURN relay for calls (see Calls and TURN); TTL default `12`, production uses `1` |
   | `MIN_ANDROID_VERSION_CODE` | no | default `0` (off). Android builds below this `versionCode` show a blocking "Update to continue" screen. Sent in `/api/config` as `min_android_version_code`; 1.0 ignores it (see Upgrading to 1.1) |
   | `STORIES_PER_DAY` | no | most stories one account may post in 24 h; default `30` |
   | `AUTH_PER_IP_PER_10MIN` | no | sign-in, sign-up and reset attempts per IP in 10 minutes; default `0`, which means the built-in `20`. Raise it only behind a NAT shared by many users (CI uses `200`) |

   `REDIS_URL`, `PORT` and `HOST` are set by the compose file.
4. Health check: `GET /healthz` returns 200 only when Postgres and Redis both
   answer (503 otherwise). The image and compose file already define it.
5. Deploy. Updating = redeploy; the container drains WebSockets on `SIGTERM`
   (clients reconnect with jittered back-off) and Redis keeps the relay queue
   in its volume (AOF).

## E-mail

Without `SMTP_URL`, e-mail verification is optional and password reset is
unavailable (the app says so). In production (`NODE_ENV=production`, as in
the image) codes are never written to logs. Any SMTP provider works; codes
are 6 digits, valid 15 (reset) or 30 (verify) minutes, stored hashed, and
allow five guesses.

### Daily e-mail cap

`EMAIL_DAILY_CAP` (default `40`) bounds every e-mail the server sends
(verification, password reset, new-device codes) in any 24 h. It is a
sliding window kept in Redis and shared by all instances, so the cap holds
at every moment, not per calendar day. Set it below your provider's daily
quota minus anything else that shares the quota.

- Verification mail stops at `floor(2/3 × cap)` (26 of 40), so a wave of
  sign-ups can't use up the headroom that password resets and device
  recovery need.
- Values below `2` are raised to `2`, with a warning in the log.
- Over the cap:
  - sign-up still succeeds (`201`) but no verification mail is sent; the
    user can ask for it again later;
  - password reset gives its usual generic `202` and sends nothing, so it
    still doesn't reveal whether an address is registered;
  - resending verification (`POST /api/auth/email/send-verification`) and
    device recovery by e-mail answer `503 email_unavailable`.
- For resending verification and device recovery, the cap is checked before
  the per-user limits, so a `503` doesn't use up the user's own budget.
  Password reset deliberately does the opposite: it takes the per-address
  budget first and only then checks the cap, so its answer (always `202`)
  and the budget it spends are the same whether or not the address has an
  account, and the cap can't be used to enumerate addresses.

## Push wake-ups (optional)

Push is off until the owner creates a Firebase project. Until then, mobile
messages wait in the relay queue until the app is opened.

1. Create a Firebase project. Add an Android app with package name
   `securelyhello.thenn.in`, and an iOS app with bundle id
   `securelyhello.thenn.in`. (The Android `namespace` and Kotlin package are
   `securelyhello.thenn`, because `in` is a Kotlin keyword. Firebase only
   needs the application id.)
2. iOS: create an APNs authentication key in the Apple Developer account and
   upload it in Firebase under Project settings → Cloud Messaging. The keys
   live in Firebase, not on this server. The app already has the Push
   Notifications capability (`ios/Runner/Runner.entitlements`,
   `aps-environment`).
3. Server: Project settings → Service accounts → generate a key; put the
   JSON (or its base64) in `FCM_SERVICE_ACCOUNT` and redeploy. Never commit
   it (`*service-account*.json` and `*firebase*adminsdk*.json` are
   git-ignored).
4. App: put the project id, sender id, API key and app ids in the app's
   `.env` (`FIREBASE_*`, see `.env.example`), then rebuild and ship the app.
   No `google-services.json` or `GoogleService-Info.plist` is needed.

A push carries no content. It is sent only to devices without a live
socket. What happens next depends on the app's version:

- **1.1 and later** say so with the device capability `data_push`. They get
  a data-only, high-priority push (at most one every 5 s per device). The
  app wakes in the background, fetches and decrypts the queue, and shows
  the real notification (names and text only if the user turned that on).
  For a call, it rings with the full-screen incoming-call screen.
- **1.0** gets a notification push saying "You have a new message" or "You
  have a new contact request" (at most one every 30 s per device). The app
  fetches the queue when it is opened.

Without Firebase, calls still ring while the app is running. During a call
a foreground service keeps it going with the screen off or the app in the
background (see "Google Play: foreground service declaration").

## Google Play: foreground service declaration

The app runs a foreground service during calls
(`android/app/src/main/kotlin/securelyhello/thenn/OngoingCallService.kt`)
with the types `phoneCall`, `microphone` and `camera`, and posts
full-screen incoming-call notifications. When the app goes on Play, fill
in Play Console → App content:

1. **Foreground service permissions.** Declare
   `FOREGROUND_SERVICE_PHONE_CALL`, `FOREGROUND_SERVICE_MICROPHONE` and
   `FOREGROUND_SERVICE_CAMERA`. For each:
   - Task: "Ongoing voice and video calls between users."
   - User impact if deferred: "The call would drop when the screen turns
     off or the user switches apps."
   - A short video showing a call that keeps going with the app in the
     background and the ongoing-call notification (Hang up / Mute).
2. **Full-screen intent.** Declare `USE_FULL_SCREEN_INTENT` for the core
   function "Calling / video calling". It is used only for incoming
   calls. On Android 14+ users can withdraw it; Settings → Calls → "Show
   calls on the lock screen" sends them to the system switch.
3. **REQUEST_INSTALL_PACKAGES must not be in the Play build.** Build with
   `--dart-define=DISTRIBUTION=play`. That turns the in-app updater off and
   removes the permission from the release manifest
   (`android/app/src/play/AndroidManifest.xml`). Check it with
   `aapt2 dump permissions app-release.aab`, or in the Play Console's
   bundle explorer.

`MANAGE_OWN_CALLS` is a normal permission. Android 14 requires it for a
`phoneCall` foreground service from an app that isn't the dialer.

## Storage

Small files never reach the server: they travel inside the encrypted
message. Larger ones are uploaded as ciphertext, and `ATTACHMENT_STORAGE`
decides where the bytes go (metadata stays in Postgres):

| Value | Where | Notes |
|---|---|---|
| `filesystem` (compose default) | the `attachments` volume on this VPS (`/data/attachments`) | back the volume up like any data |
| `s3` | any S3-compatible store: MinIO on your VPS, AWS S3, Cloudflare R2, Backblaze B2 | set `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`; `S3_PATH_STYLE=1` (default) for MinIO |
| `postgres` | the `attachments` table | simplest; uses database storage |

Blobs expire after `ATTACHMENT_TTL_DAYS` and are deleted by the hourly
sweep wherever they live. Pick one backend before launch: rows remember
where their bytes are, so switching later leaves existing files readable
only if the old backend is still configured.

MinIO next to the app on the same VPS, if you prefer S3:

```yaml
  minio:
    image: minio/minio:RELEASE.<pin a current tag>
    command: server /data
    environment:
      MINIO_ROOT_USER: ${S3_ACCESS_KEY_ID}
      MINIO_ROOT_PASSWORD: ${S3_SECRET_ACCESS_KEY}
    volumes: [minio-data:/data]
```

with `ATTACHMENT_STORAGE=s3`, `S3_ENDPOINT=http://minio:9000`, and a bucket
created once (`mc mb local/securelyhello`).
Request bodies for uploads go up to `ATTACHMENT_MAX_MB`, so the proxy must
allow bodies that large on `/api/attachments`.

## Moderation

Users can block and report each other in the app. Set `ADMIN_TOKEN` (a
random string of at least 32 characters, e.g. `openssl rand -hex 32`) to
review reports. Without it the admin endpoints answer 404.

```
curl -H "Authorization: Bearer $ADMIN_TOKEN" https://api.example.com/api/admin/reports
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
     -d '{"status":"resolved"}' https://api.example.com/api/admin/reports/<report id>
curl -X POST   -H "Authorization: Bearer $ADMIN_TOKEN" https://api.example.com/api/admin/users/<user id>/suspend
curl -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" https://api.example.com/api/admin/users/<user id>/suspend
```

A report contains only what the reporter chose to share (reason, notes and
optionally their last 20 messages with that person); the server can't read
anything else. Suspending signs the account out everywhere and blocks
sign-in until lifted.

### Spam controls

The server can't read messages, so it judges accounts by how other people
react to them (`src/spam.js`). An account is restricted, meaning it can't
send new contact requests while its existing chats keep working, when:

- 3 different people report it within a week (restricted for 7 days);
- 5 different people block it within a week (7 days);
- 10 or more of its requests are rejected in a day, at least 80% of those
  it got an answer to (1 day).

Accounts less than a day old can send 10 contact requests per day. Signups
need a solved proof-of-work challenge, are capped at 10 per IP per day
(`SIGNUPS_PER_IP_PER_DAY`; raise it if many users share an address, as
behind carrier-grade NAT), and refuse disposable e-mail domains.

```
curl -H "Authorization: Bearer $ADMIN_TOKEN" https://api.example.com/api/admin/restricted
curl -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" https://api.example.com/api/admin/users/<user id>/restriction
```

## Several instances

Instances share Postgres and Redis and need nothing else: no sticky
sessions. Each holds its own WebSockets and records in Redis which users and
devices it serves; a relay push, signal or "close this device" for a socket
on another instance goes there over Redis pub/sub (`src/bus.js`). Presence
counts a user online while any instance holds a socket of theirs, and an
instance that dies stops counting within 75 s. The hourly sweep runs on one
instance at a time.

With Docker Compose, scale the service (`docker compose up -d --scale
app=3`) and let the proxy balance across them. Size Redis for it: every
instance keeps two connections (one for pub/sub).

Pub/sub is fire-and-forget. A frame lost while an instance restarts is the
same as one sent to a socket that just dropped: the message is still in the
relay queue, and the client drains it when it reconnects.

## Calls and TURN

Calls and direct links use STUN to find a path. Behind symmetric NAT (most
mobile carriers) they need a TURN relay. The compose file includes coturn
under the `turn` profile; it uses the host's network, because TURN needs
public UDP ports (3478 and the relay range 49160-49200).

1. Pick a long random secret and set it as `TURN_SECRET` for both `app` and
   `coturn`, with `TURN_REALM` and `TURN_EXTERNAL_IP` (the VPS's public IP).
2. Set `TURN_URLS=turn:turn.example.com:3478?transport=udp,turn:turn.example.com:3478?transport=tcp`
   for `app`.
3. `docker compose --profile turn up -d`, and open UDP 3478, TCP 3478 and UDP
   49160-49200 in the firewall.

The app asks `GET /api/turn` for credentials that expire after
`TURN_TTL_HOURS` (default 12), signed with the shared secret (coturn's
`use-auth-secret`); nothing long-lived is built into the app. TURN only
forwards DTLS-encrypted traffic: it learns IP addresses and timing, not
content.

## Metrics

Set `METRICS_TOKEN` (32+ random characters) and scrape `GET /metrics` on each
instance with `Authorization: Bearer <token>`. Without the token the route
doesn't exist. It reports requests and latency per route pattern, open
WebSockets, relay pushes delivered live versus queued, the Postgres pool
queue and process memory and CPU. Labels are route patterns and status
codes only, never ids or names.

## Proxy requirements

- Everything the app calls lives under `/api/` (WebSocket: `/api/ws`), so a
  bot filter that exempts `/api/` lets the mobile client through.
- WebSocket upgrade must pass through; idle timeout should exceed 60 s (the
  server pings every 30 s, the client every 25 s).
- The app enforces its own per-account and per-IP limits in Redis; they sit
  well inside a proxy limit of 50 req/s per IP.

## TLS, HSTS and certificate pinning

- Serve the API over HTTPS only. Release builds of the app refuse a plain
  `http://` server address (except `127.0.0.1`/`localhost`).
- Add HSTS at the proxy, e.g. in Traefik a headers middleware with
  `stsSeconds=31536000` and `stsIncludeSubdomains=true`.
- Pinning is **off by default** (`API_CERT_PINS` empty). Optional pinning:
  build the app with the SHA-256 of the server's public key, plus a backup
  key that isn't deployed yet. The app then refuses any other key, even one
  with a valid certificate. The app compares the pins with the server's own
  (leaf) certificate key only, not with intermediates or roots.

  ```
  # current key (from the live server)
  openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null 2>/dev/null \
    | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
    | openssl dgst -sha256 -binary | base64
  # backup key: generate it now, keep it offline, deploy it if the current one is lost
  openssl ecparam -genkey -name prime256v1 -noout -out backup.key
  openssl pkey -in backup.key -pubout -outform der | openssl dgst -sha256 -binary | base64

  flutter build apk --dart-define=API_BASE_URL=https://api.example.com \
    --dart-define=API_CERT_PINS=<current>,<backup>
  ```

  Renew certificates with the same key (certbot `--reuse-key`; in Traefik use
  a fixed certificate instead of automatic ACME keys), and always ship the
  backup pin. Never pin a leaf whose key rotates on renewal, as default ACME
  setups (including Traefik's) do. Pinning the ISRG (Let's Encrypt) roots
  instead would survive key rotation, but the app doesn't support it yet: it
  would need a check of the certificate chain in `lib/core/networking/tls_pinning.dart`.
  If the key ever changes to one that isn't pinned, every installed app
  stops connecting until it is updated.

## Upgrading to 1.1

The 1.1 server works with the 1.0 app (`versionCode 1`): new payload kinds
(stories, data pushes) go only to devices that announce the capability, and
1.0 ignores the new `/api/config` fields and acknowledgement receipts.

1. **Back up the database** (a Neon branch or `pg_dump`).
2. Redeploy. Three migrations run at boot, all additive (new tables and
   nullable or defaulted columns, nothing dropped or rewritten):

   | Migration | Adds |
   |---|---|
   | `016_stories.sql` | `devices.capabilities`; tables `stories` and `story_keys` (ciphertext and per-device sealed keys; rows expire after 24 h and are swept) |
   | `017_privacy.sql` | `users.show_presence` (default `true`: nothing changes until a user turns it off) |
   | `018_account.sql` | `users.pending_email`; the `email` purpose for e-mail codes |

3. New variables, all optional; the defaults are right for now:
   `MIN_ANDROID_VERSION_CODE=0`, `STORIES_PER_DAY=30`,
   `AUTH_PER_IP_PER_10MIN=0` (built-in 20).
4. Publish the app: build the APKs and run `tools/release_apk.py` (see its
   header and `website/README.md`). It writes `website/download/` with the
   APKs and `latest.json`, which 1.1 checks every 12 hours. Deploy the
   website with that folder.
5. **Only once most users run 1.1**, set `MIN_ANDROID_VERSION_CODE=2` to
   make 1.1 the minimum. 1.0 has no update screen, so it is not blocked by
   this; it keeps working against this server.

Smoke test as below, plus: post a story and see it on a contact's phone,
change a profile photo while a contact is offline, and hang up a call (the
other phone should end it within a second).

## Upgrading production from 0d52749

Production runs commit `0d52749`. Going to this version:

1. **Environment already set** (keep as is): `SMTP_URL` (Resend SMTP),
   `MAIL_FROM`, `TOTP_ENCRYPTION_KEY`, `ADMIN_TOKEN`, `METRICS_TOKEN`,
   `TURN_URLS`, `TURN_SECRET`, `TURN_TTL_HOURS=1`, `ATTACHMENT_*`,
   `POW_BITS`, `EMAIL_DAILY_CAP=40`. **Never change `TOTP_ENCRYPTION_KEY`**:
   users with two-step verification would be locked out.
2. **Add**: `INVITE_BASE_URL=https://securelyhello.thenn.in/i/`.
3. **Back up the database first** (a Neon branch or `pg_dump`). Migrations
   `002` to `018` are applied automatically at boot (`MIGRATE_ON_START=1`,
   under an advisory lock, so several instances are fine).
4. **Keep the `attachments` volume** (`/data/attachments` with
   `ATTACHMENT_STORAGE=filesystem`): it must persist across redeploys, or
   uploaded files are lost while their rows remain.
5. Redeploy, then smoke test:

   ```
   curl -fsS https://api.hello.thenn.in/healthz            # 200: Postgres and Redis answer
   curl -fsS https://api.hello.thenn.in/api/config         # password_reset: true (SMTP works)
   curl -fsS -H "Authorization: Bearer $METRICS_TOKEN" https://api.hello.thenn.in/metrics | head
   curl -fsS -H "Authorization: Bearer $ADMIN_TOKEN" https://api.hello.thenn.in/api/admin/reports
   ```

   Then, in a release build of the app: sign up (the verification mail
   arrives), sign in on a second device and approve it, send a message and
   an attachment, open an invite link (`https://securelyhello.thenn.in/i/…`),
   make a call over mobile data (TURN), reset a password, and check that a
   2FA user can still sign in.
6. **After verifying**, delete the old variables, which this version no
   longer reads: `EMAIL_PROVIDER`, `EMAIL_FROM`, `EMAIL_API_KEY`,
   `CODE_HMAC_KEY`, `TURN_TTL_SECONDS`.

## Running migrations by hand

```
docker compose run --rm app node src/migrate.js
```

## Local development

`scripts/dev.sh` (repo root) starts Postgres and Redis in Docker, migrates and
runs the server on `:8787`. `npm test` in this folder runs the suite against
those containers (it uses its own `securelyhello_test` database and Redis
database 15).
