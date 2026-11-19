# Privacy Policy

_Draft — have a lawyer review this before publishing. Replace the bracketed
parts with your details._

Last updated: 19 November 2026

Securely Hello ("the app", "we") is operated by Thenn (Tirth Joshi), India, contact
hello@thenn.in. This policy explains what the app and its server process,
and why. The short version: **we cannot read your messages, calls or files.**

## What never leaves your device

- The text of your messages, your calls, and the files you send. They are
  encrypted on your device before they leave it and can only be decrypted on
  the devices of the people you are talking to (and your own other devices).
- Your private keys and your chat history.

## What the server stores

| Data | Why | How long |
|---|---|---|
| E-mail address | Sign-in, verification and password-reset codes | Until you delete your account |
| Password | Sign-in. Stored only as a one-way scrypt hash | Until you change it or delete your account |
| Username and display name | So contacts can find and recognise you | Until you change them or delete your account |
| Public keys of each of your devices, a device name you can edit, and when each device was last active | So contacts can encrypt to your devices; so you can manage linked devices | Until the device is removed |
| Your contacts and contact requests | So only accepted contacts can reach you | Until removed or you delete your account |
| Blocks and reports you make | To stop unwanted contact and handle abuse | Blocks until you lift them; reports up to 1 year |
| Encrypted messages waiting for a device that is offline | Delivery | Deleted on delivery, at most 24 hours |
| Encrypted files too large to travel inside a message | Delivery | Deleted after 30 days |
| A one-way hash of your e-mail address | Lets people who have your address in their phone contacts find you, but only if you turn on "Findable by e-mail" (off by default). Address books you check are compared and discarded, never stored | Until you delete your account |
| Two-step verification secret (encrypted) and hashed recovery codes, if you turn it on | Asking for a code at sign-in | Until you turn it off |
| Invite links you create (hashed) and how often each was used | So the people you invite can add you | Until they expire (30 days) |
| Whether your account is temporarily limited for spam, and why | Protecting other users. Based on reports, blocks and rejected requests, never on message content | Up to 7 days per limit |
| Session tokens (hashed) | Keeping you signed in | Up to 90 days of inactivity |
| Push-notification token (if enabled) | Waking your phone when something arrives | Until you sign out or disable notifications |
| Online status and last-seen time | Shown to your contacts | Online: while connected; last seen: 90 days |
| Technical logs (time, route, status code, user id; never message content, e-mail addresses or search terms) | Security and reliability | 30 days |

Encrypted messages and files are stored as ciphertext: we hold no key that
could decrypt them.

## Third parties

- **Hosting**: Manage Server (VPS) in India, Neon (PostgreSQL) in Singapore.
- **E-mail delivery**: Resend receives your address and the code.
- **Push notifications** (Android/iOS, if enabled): Google Firebase Cloud
  Messaging and Apple Push Notification service learn that *something*
  arrived for your device at a given time. They never receive message
  content, the sender or the conversation.
- **Calls**: may be relayed by our TURN server when a direct connection is
  impossible. Calls stay end-to-end encrypted.

We do not sell data, show ads, or use analytics or tracking SDKs.

## Your rights

You can view and change your profile in the app, remove devices, and
**delete your account** (Settings → Delete account), which removes
everything the server holds about you. For other requests (access,
correction, objection) contact hello@thenn.in. You may complain to the Data Protection Board of India
or your local data-protection authority.

## Children

The app is not intended for children under 18 without the verifiable consent of a parent or lawful guardian, as required by the Digital Personal Data Protection Act, 2023.

## Changes

We will announce material changes in the app before they take effect.
