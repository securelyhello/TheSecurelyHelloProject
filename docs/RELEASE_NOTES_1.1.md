# Securely Hello 1.1

Version `1.1.0`, build `2`. Android from 7.0 up.

## What's new

**Stories.** Share a text, photo or video for 24 hours. Choose who sees
it: all your contacts, only some people, or everyone except some. You see
who viewed it, and people can reply or react; replies arrive as normal
encrypted messages. Delete a story early whenever you like, and mute
anyone's stories. Each story is encrypted with its own key, so the server
only ever stores something it can't read.

**Calls that keep going.** A call carries on with the screen off or the
app in the background, with an ongoing notification to mute or hang up.
Incoming calls ring full-screen with Accept and Decline, even on the lock
screen. Switch between earpiece, speaker and Bluetooth; the screen turns
off when the phone is at your ear; a video call shrinks to
picture-in-picture when you leave the app. A "low data" mode for poor
connections. Hanging up now ends the call on the other phone within a
second.

**Better notifications.** Reply or mark as read straight from the
notification. Messages are grouped per chat with names and photos. Mute a
single chat for eight hours, a week or always, and choose the
notification sound. Message text stays hidden in notifications ("New message") unless
you turn it on.

**Keep chats tidy.** Pin, archive and mute chats; star messages and find
them again; forward messages; search inside your messages. Unsent text is
kept as a draft. A new Calls tab shows your call history.

**A fresh look.** A new design, a new icon, fonts built into the app (no
more downloads from Google), and Gujarati alongside English and Hindi.
"New chat" now opens your contacts directly, and finding new people sits
in the same place.

**Privacy and account.** Hide when you're online, choose who sees your
profile photo, set a default timer for disappearing messages, and block
screenshots in a single chat. Change your username or e-mail, sign out
every other session, and download what the server knows about your
account.

**Updates inside the app.** If you installed from the website, the app
tells you when there's a new version, downloads the right file for your
phone and checks it really comes from us before installing.

## Fixed

- Opening an invite link from another app no longer starts a second copy
  of Securely Hello over that app. The invite now opens as a small sheet.
- A new profile photo now reaches contacts who were offline for more than
  a day, and contacts' devices added later.
- The other side of a call no longer stays connected for 4–5 seconds after
  you hang up.
- Phones on Android 7.0 can connect again (they lacked the certificate
  authority the server uses). The website also offers smaller APKs, about
  a third of the size, for phones with little space.
- Signing out with a chat open no longer crashes.

## Security

- A device added to your own account now needs an approval signed by one
  of your existing devices, checked on your phone. A device the server
  lists without one gets nothing until you confirm it.
- A quoted message is shown from your own copy, not from what the sender
  claims it said.

## For the operator

- **Migrations** (additive, run at boot): `016_stories.sql`,
  `017_privacy.sql`, `018_account.sql`. See `server/DEPLOY.md`, "Upgrading
  to 1.1".
- **New environment variables**, all optional:

  | Name | Default |
  |---|---|
  | `MIN_ANDROID_VERSION_CODE` | `0` (no minimum) |
  | `STORIES_PER_DAY` | `30` |
  | `AUTH_PER_IP_PER_10MIN` | `0` (keeps the built-in 20 per IP, as in 1.0) |

- `MIN_ANDROID_VERSION_CODE` must be a whole number and never above the newest
  published build; a bad value stops the server from starting.
- The server still serves the 1.0 app. Set `MIN_ANDROID_VERSION_CODE=2`
  only once most people have updated.
- Push stays off until the `FIREBASE_*` values (app) and
  `FCM_SERVICE_ACCOUNT` (server) are set. With them, 1.1 gets data-only
  wake-ups that show the real notification and ring for calls.
- Google Play: the app declares phone-call, microphone and camera
  foreground services. The declaration text is in `server/DEPLOY.md`.
  Build Play bundles with `--dart-define=DISTRIBUTION=play`, which removes
  the in-app updater and its install permission.
- Releasing for the website: `tools/release_apk.py` (APKs plus
  `latest.json`).

What 1.1 didn't do, and why: [KNOWN_ISSUES.md](KNOWN_ISSUES.md).
