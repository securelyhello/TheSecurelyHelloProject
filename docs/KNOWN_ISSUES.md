# Known issues

What was checked for 1.1, what was fixed, and what is still open. Keep this
list current: move an item to "Fixed" with the commit that fixed it.

## How the app is checked

- `integration_test/ui_flow_test.dart` walks the real app against a real
  server and saves a screenshot of each screen. Its last part is a **stress
  pass** that fails on any overflow or layout error:
  - a 360×640 phone, light theme, Hindi, text at 1.3×;
  - a 412×892 phone, dark theme, English, text at 1.3×;
  - a 1280×800 window with two panes;
  - a 56-character contact name, a 2,000-character message, an unbroken
    URL and a line of emoji;
  - the keyboard up (the composer must stay above it).

  Its screenshots are named `zz_*`, and the website build skips them.
- `integration_test/e2e_chat_test.dart` runs two to three real clients. It
  covers offline and relay delivery, two devices on one account, calls
  (including a peer that vanishes) and profile photos for a contact who
  was offline.

## Fixed in 1.1

| Area | Problem | Fix |
|---|---|---|
| Invites (Android) | An invite link opened from a browser or chat app started a second full copy of the app over that app. To the owner this looked like the invite UI taking over the whole screen. | `launchMode="singleTask"`. The invite prompt is now a compact, dismissible bottom sheet. |
| Invites | The avatar in the invite dialog's icon slot was stretched to the slot's width (232 px). | `AvatarWidget` keeps its own size in any slot. |
| Profile photos | A changed photo didn't reach existing contacts who stayed offline for more than a day. The relay keeps things for 24 h, but the photo was counted as sent once queued. | Sent through the relay only, tracked per device and acknowledged. Sent again after 20 h if unacknowledged. |
| Profile photos | A contact's devices added later never got the photo. | Tracked per device. |
| Calls | The other side dropped 4–5 s after a hang-up. | The hang-up goes over the call's own data channel first (about 130 ms locally). A connection that's lost ends the call after 1 s. |
| Calls | When one side vanished (app killed, network gone), the other side only noticed after about 6 s. | Its control channel closing is noticed: about 1 s. |
| Chat header | On a small phone with large text, the "online" / "last seen" line was squeezed to nothing (with a 3 px overflow). | The status and the connection badge share the line. |
| Fonts | The app downloaded its fonts from fonts.gstatic.com on first use, a request to Google that showed the user's IP address. Text fell back to the system font when it failed. | Fonts are bundled in the app (`assets/fonts/`): in 1.1 Plus Jakarta Sans, Inter and Source Code Pro; in 1.2 Plus Jakarta was replaced by Chillax for headings. `google_fonts` is gone. |
| Drafts | Signing out with a chat open crashed: the chat saved its draft into storage sign-out had already closed. Found by the UI walkthrough. | The draft is dropped once storage is closed (`test/chat_organisation_test.dart`). |
| Linked devices | A device added to your own account was trusted as soon as the server listed it. | Your own devices must carry an approval signed by one of your devices, checked on the phone. Unsigned ones are shown with a "Confirm" button and get nothing until confirmed. |

## Android versions (checked 19 Nov 2026)

The owner reported that phones on Android 11 and older couldn't get the
app. The APK published at securelyhello.thenn.in was downloaded the way a
phone does and checked:

| Check | Result |
|---|---|
| Lowest Android version | `minSdkVersion` 24, which is Android 7.0. No dependency asks for more. |
| CPU types | arm64-v8a, armeabi-v7a (32-bit) and x86_64 are all included. |
| Signature | APK Signature Scheme v2, RSA 4096, release key `78:8E:…:B6:E1`. `apksigner` verifies it for API 24, 26, 28 and 30. |
| Packaging | 16 KB zip alignment; dense resource table (no newer-only encodings). |
| Download | Chrome, Samsung Internet, Mi Browser, UC, Opera Mini, Firefox, WhatsApp's in-app browser and Android's DownloadManager (7, 9 and 11) all get the APK with the right MIME type. Only requests without a user agent are refused (the site's bot filter). |
| Install and run | The live APK, installed with `adb` on Android 11 and Android 7.0 emulators: it installs, starts and shows the welcome screen on both. |
| Root certificates | Android 7.0 has no ISRG Root X1 (`6187b673.0` is missing from its store), so 1.0 can't reach the server there. |

What did not work, and what changed:

- **Android 7.0** doesn't trust ISRG Root X1, which Let's Encrypt (the API
  and the website) chains to. The app now bundles the ISRG roots for its
  own connections (`lib/core/networking/app_trust.dart`). The *website*
  still can't be opened in Android 7.0's browser; that needs a certificate
  from another CA on the web server, or the APK shared another way.
- **Size**: the universal APK is 125 MB, and 47 MB of that is x86_64 code
  phones never use. On old phones with little free space or a slow
  connection the download or install can fail. `tools/release_apk.py
  --split` now publishes 64-bit (about 46 MB) and 32-bit (about 37 MB)
  APKs, the site can offer them, and the updater picks the right one.

If someone still can't install, the exact message tells the cause:

| Message | Cause |
|---|---|
| "App not installed" / "package conflicts" | An older copy signed with another key (a test build) is installed. Uninstall it first. |
| "There was a problem parsing the package" | The download is incomplete. Download again, or use the smaller APK. |
| "Not enough storage" / "App not installed" on a nearly full phone | Too little space. Use the smaller APK. |
| "Blocked by Play Protect" | Play Protect's warning for apps from outside Play. Tap "More details", then "Install anyway". Publishing on Play removes this. |
| The site doesn't open (Android 7.0) | The certificate issue above. |

## Open

| Area | Problem | Notes |
|---|---|---|
| Translations | Hindi and Gujarati cover sign-in, the tabs, chat list, composer, contacts and the main settings headings. Newer screens are still English in both: stories ("My story"), the "Groups" filter, call records ("Incoming voice call · 0:02"), the account screen, notification settings and most dialogs. | The strings are hard-coded. Move them to the ARB files screen by screen. `test/l10n_test.dart` checks that every ARB key exists in all three languages. |
| RTL | There is no right-to-left language, so RTL layout is only covered by widget tests of single widgets. | Layouts use `EdgeInsetsDirectional` where it matters. |
| Attachments | Closing the app while an attachment uploads drops it silently. The message is only stored once the upload finishes. | Resend it by hand. A pending row with a retry is planned. |
| Long messages | Very long messages are shown in full; there is no "Read more". | Cosmetic. |
| Invites (Android) | The full-screen takeover hasn't been reproduced on a device. An `am start` from the shell (Android 7.0 emulator) doesn't show it, because the shell isn't a link tapped inside another app's task. The launch-mode fix is based on how Android routes `VIEW` intents. | Check on a phone: open an invite link from WhatsApp or Chrome while the app is running. |

## Not done in 1.1 (section 7 of the brief)

Built: pin, archive, mute (with durations), star, search inside messages,
forward, drafts; the calls tab with history and missed-call badge, audio
output picker (earpiece, speaker, Bluetooth, wired), a low-bandwidth call
mode; last-seen/online visibility, profile-photo visibility, a default
disappearing-message timer, per-chat screenshot blocking; username and
e-mail change, sign out other sessions, download your data; Gujarati,
haptics, notification sounds, and a "What's new" sheet.

Left for later, and why:

| Item | Why it was left |
|---|---|
| Link previews | Fetching a preview leaks the link to the site (from the sender's IP) or needs a server-side fetcher that sees links. Needs a design decision on which side fetches, and an opt-in. |
| Chat wallpapers | Lower value than the rest; the new theme had to settle first. |
| View-once media | Can't be enforced against screenshots or a modified client. Needs careful wording so it doesn't promise more than it does. |
| Image editor (crop, draw, blur) | A large UI on its own. Sending already strips metadata. |
| Shared media gallery per chat | Needs an index of attachments by chat in local storage (a migration) and thumbnails. Next on the list. |
| Media quality options | Images are sent at a fixed size and quality today; a setting needs the encoder work done first. |
| Group roles, @mentions, invite links, polls, announcement-only groups, group description and photo | Each one changes the signed group state that every member checks. They need a group-state version bump that 1.0 members can live with, so they go together in one release. |
| Group calls | Calls are one-to-one peer-to-peer. Group calls need a mesh (fine up to about 4) or an SFU on the server, which can't be end-to-end encrypted without insertable streams. |
| Screen sharing | Needs a `mediaProjection` foreground service type and its own Play declaration; left out to keep the 1.1 review simple. |
| In-app sounds (send/receive) | Notification sounds are done. In-chat sounds were left so the app stays quiet by default. |
