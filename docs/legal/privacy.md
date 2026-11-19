# Privacy Policy

Last updated: 20 November 2026

Securely Hello is run by Thenn (Tirth Joshi), India. You can reach us at
hello@thenn.in. This policy explains what the app and our server process,
why, and for how long.

**In short: we cannot read your messages, listen to your calls, or see your
files and stories.** They are encrypted on your phone and can only be opened
by the people you send them to.

## What stays on your devices

- The content of your messages, calls, files, voice notes and stories. They
  are encrypted before they leave your device and decrypted only on the
  devices of the people you are talking to, and on your own other devices.
- Your private keys and your chat history.
- Your notification settings, mutes and drafts.

## What our server keeps

| What | Why | For how long |
|---|---|---|
| Your e-mail address | Signing in, verification and password-reset codes | Until you delete your account |
| Your password | Signing in. We keep only a one-way scrypt hash, never the password | Until you change it or delete your account |
| Username and display name | So your contacts can find and recognise you | Until you change them or delete your account |
| Each device's public keys, its name and when it was last active | So contacts can encrypt to your devices, and you can manage them | Until the device is removed |
| What each device supports (for example stories) | So nobody sends a device something it cannot open | Until the device is removed |
| Your contacts and contact requests | So only people you accepted can reach you | Until removed, or you delete your account |
| Blocks and reports you make | To stop unwanted contact and deal with abuse | Blocks until you lift them; reports up to 1 year |
| Encrypted messages waiting for an offline device | Delivering them | Deleted when delivered, and after 24 hours at most |
| Encrypted stories, and which devices each was shared with | Delivering stories to the people you chose | 24 hours, or until you delete the story |
| Encrypted files too large to travel inside a message | Delivering them | Deleted after 30 days, or with the story they belong to |
| A one-way hash of your e-mail address | Letting people who have your address in their phone find you, only if you turn on "Findable by e-mail" (off by default). Address books you check are compared and discarded, never stored | Until you delete your account |
| Your two-step verification secret (encrypted) and hashed recovery codes | Asking for a code when you sign in | Until you turn it off |
| Invite links you create (hashed) and how often each was used | So the people you invite can add you | Until they expire, after 30 days |
| Temporary spam limits on your account, and why | Protecting other people. Based on reports, blocks and rejected requests, never on what you write | Up to 7 days per limit |
| Session tokens (hashed) | Keeping you signed in | Up to 90 days without use |
| Your push-notification token, if notifications are on | Waking your phone when something arrives | Until you sign out or turn notifications off |
| Online status and last-seen time | Showing your contacts whether you are around | Online: while connected; last seen: 90 days |
| Technical logs: time, request path, result and account id, never content, e-mail addresses or searches | Security and keeping the service running | 30 days |

We hold no key that could decrypt your messages, stories or files.

## Who else is involved

- **Hosting:** our server runs on a VPS from Manage Server in India; the
  database is hosted by Neon in Singapore.
- **E-mail:** Resend sends verification and reset codes, so it receives your
  address and the code.
- **Push notifications** (only if turned on): Google Firebase Cloud
  Messaging and Apple's push service learn that something arrived for your
  device and when. They never receive content, the sender or the chat.
- **Calls:** when two phones cannot connect directly, our own relay server
  passes the call along. It stays end-to-end encrypted.
- **Updates:** the Android app downloaded from our website checks
  securelyhello.thenn.in for new versions about twice a day. Like any
  website, ours sees the address the request comes from.

The app has no ads, no analytics and no tracking. Its fonts come with the
app, so it makes no requests to font services. We do not sell or share your
data.

## Your rights

In the app you can see and change your profile, remove devices, and delete
your account (Settings → Delete account), which deletes everything our
server holds about you. To ask for a copy of your data, a correction, or
anything else, write to hello@thenn.in. If you are not satisfied with our
answer, you may complain to the Data Protection Board of India.

## Children

Securely Hello is not meant for people under 18 without the verifiable
consent of a parent or lawful guardian.

## Security

Messages, calls, files and stories are end-to-end encrypted with the Signal
protocol design (X3DH and the Double Ratchet). Connections to our server use
TLS. You can compare safety numbers with a contact to be sure nobody is in
between.

## Changes to this policy

If we change this policy in a way that matters, we will tell you in the app
before the change takes effect.

## Contact and grievances

Write to hello@thenn.in. Our Grievance Officer is Tirth Joshi, at the same
address. We acknowledge complaints within 24 hours and resolve them within
15 days.
