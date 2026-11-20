# Securely Hello 1.2

Version `1.2.0`, build `3`. Android from 7.0 up.

## What's new

**Find people has its own tab.** The bottom bar (and the side rail on
wide screens) now reads Chats, Find people, Calls, Settings. Search by
username, send and answer contact requests, and invite friends from one
place. The badge for incoming requests moved from Chats to Find people, so
the Chats badge counts unread messages only. Empty states in Chats and the
contact lists take you to the new tab.

**Settings shows your version and checks for updates.** The App updates
section shows the version you have (the real one, not a fixed number), the
status of the last check, when it was checked, the size of the update, and
a Check for updates button. The app still checks on its own about every 12
hours.

**A new look and a new icon.** A new "Sealed note" logo: a speech bubble
with an envelope flap. The app uses paper and ink colours with pear for
actions, in light and dark themes. Headings, names, titles and buttons are
set in Chillax; tab labels use Chillax Medium. The launch screen, the
Android icon and the notification icon match.

**Calls fit on small and sideways screens.** The call screen keeps its
controls on screen on short phones and in landscape.

**A redesigned website.** The product page uses the new look, and it
works on phones and on wide screens. The screenshots show the Find people
tab.

## Fixed

- The Settings screen showed a fixed version number. It now shows the
  version the app was built with.
- The Android button on the invite page was hidden. It now links to the
  APK on the website.
- Switching between tabs no longer breaks when the app is locked.
- Some labels in Settings were cut off. They now wrap.
- The call screen's controls could fall off the bottom of short screens.

## Updates inside the app

- The download is checked against the size in the update file while it
  downloads, not only at the end. A file that is too large is stopped.
- Old downloaded APKs are deleted in the background, so an update doesn't
  leave copies of previous versions on the phone.
- The app identifies itself to the server as `SecurelyHello/1.2.0`
  (Android for the updater, Flutter for the API).

## Fonts

Chillax is not in git, because of its licence (ITF Free Font License,
text in `assets/fonts/FFL-Chillax.txt`). Fetch the font files once with
`python3 tools/fetch_fonts.py` before building. The script puts them in
`assets/fonts/` and `website/assets/fonts/`.

## For the operator

- Publish the release with `tools/release_apk.py` as before. The update
  file (`latest.json`) now carries each APK's size, which the updater uses
  to check the download. Older files without a size still work.
- No new database migrations: the newest is `018_account.sql`, from 1.1.

What 1.2 didn't do, and what is still open: [KNOWN_ISSUES.md](KNOWN_ISSUES.md).
