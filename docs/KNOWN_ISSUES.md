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

## Open

| Area | Problem | Notes |
|---|---|---|
| Translations | Many screens are still English when Hindi is chosen: settings rows, the chat header ("online", "typing"), call records ("Incoming voice call · 0:02") and dialogs. | The strings are hard-coded. They're being moved to the ARB files with Gujarati. |
| RTL | There is no right-to-left language, so RTL layout is only covered by widget tests of single widgets. | Layouts use `EdgeInsetsDirectional` where it matters. |
| Attachments | Closing the app while an attachment uploads drops it silently. The message is only stored once the upload finishes. | Resend it by hand. A pending row with a retry is planned. |
| Long messages | Very long messages are shown in full; there is no "Read more". | Cosmetic. |
| Invites (Android) | The full-screen takeover couldn't be reproduced on a device in the cloud session (there's no emulator). The launch-mode fix is based on how Android routes `VIEW` intents. | Check on a phone: open an invite link from WhatsApp or Chrome while the app is running. |
