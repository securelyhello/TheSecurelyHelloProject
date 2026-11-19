# Securely Hello — brand

Playful but grown-up: a friendly hello that keeps your secrets. The look is
calm, rounded and warm, never cartoonish, and never borrowed from another
messenger.

## The mark

A speech bubble shaped like a shield, with a keyhole at its heart. A small
coral sparkle at the top right is the "hello".

| File | Use |
|---|---|
| `assets/brand/logo.svg` | The app icon: the mark on the Iris gradient, with rounded corners. |
| `assets/brand/mark.svg` | The mark alone, white on transparent: on photos, on Iris, in monochrome. |
| `website/assets/og.png` | Social preview (1200×630). |

Every platform icon (Android adaptive, monochrome and notification, iOS,
macOS, Windows, web, website favicon) is generated from these two files by
`tools/make_icons.py`. Change the SVGs, then run the script; don't edit the
PNGs by hand.

**Do**

- Keep clear space of at least a quarter of the icon's width around it.
- Use the white mark on Iris, on ink (`#0E0F1C`) or on a photo dark enough
  for white to read.
- Keep it at 24 px or larger (16 px only as a favicon).

**Don't**

- Recolour the mark, outline it, add shadows to it, or rotate it.
- Put the gradient icon on a busy background.
- Separate the sparkle from the bubble, or use the keyhole alone.

## Colour

| Token | Light | Dark | Use |
|---|---|---|---|
| Iris (accent) | `#5546D9` | `#9C8FFF` | Primary actions, outgoing bubbles, links on surfaces |
| Iris gradient | `#7B6CFA` → `#4434C9` | same | The icon, hero moments |
| Ember | `#FF7A59` | `#FF7A59` | Sparkle, story rings, small highlights; never body text |
| Mint | `#1FA463` | `#3DD69B` | Online, success, answer a call |
| Ink (background) | `#F7F6FC` | `#0E0F1C` | Screens |
| Surface | `#FFFFFF` | `#15162A` | Bars, cards, incoming bubbles (dark: `#1C1E36`) |
| Text | `#16152C` / `#4A4868` / `#65638A` | `#F4F4FB` / `#BCBEDA` / `#9295B8` | Primary / secondary / muted |
| Danger | `#C92A3A` | `#FF7A7A` | Destructive actions, missed calls |

All text meets WCAG AA (4.5:1) on its background, muted text included. The
tokens live in `lib/shared/theme/app_palette.dart`. Screens use
`context.palette`, never raw colours.

## Type

| Face | Use |
|---|---|
| Plus Jakarta Sans (500–800) | Titles, names, buttons on the website |
| Inter (400–700) | Everything people read |
| Source Code Pro (400, 600) | Safety numbers and codes |

The fonts ship with the app (`assets/fonts`, SIL Open Font License). The app
never fetches fonts from the network. Hindi and Gujarati use the phone's own
fonts.

## Shape, depth and motion

- **Rounded.** Radii are 8, 12, 16, 20 and 28 (pill for buttons and chips).
  Bubbles use 18 with a tighter corner where messages group.
- **Soft depth.** Elevation comes from surface colour and a light border,
  plus a soft shadow in the light theme. No heavy drop shadows.
- **Motion.** 150, 220 and 320 ms with an ease-out curve. Movement is small
  and purposeful: sheets rise, the welcome logo floats, story rings fill.
  With "remove animations" on, things appear without moving.
- **Touch.** Every tap target is at least 48 dp.

## Tone of voice

Speak like a thoughtful friend who happens to know security.

- **Plain words.** "Only you and them can read this", not "E2EE-protected
  payload".
- **Short sentences.** One idea each. No exclamation marks in errors.
- **Honest.** Say what we can't do ("we can't recover your chats") as
  clearly as what we can.
- **Warm, not cute.** A friendly hello, never a joke at the user's expense.
- **Indian English spelling.** Colour, organise, licence. Dates are
  "20 November 2026".

| Instead of | Write |
|---|---|
| "Error 403: not_contacts" | "You can only message people in your contacts." |
| "Operation failed successfully" | "That didn't work. Try again." |
| "Your data is 100% secure!!!" | "Messages are end-to-end encrypted. Not even we can read them." |
