# Securely Hello — brand

Playful but grown-up: a friendly hello that keeps your secrets. The look is
warm paper and ink with one bright pear-yellow for the action. It is calm and
rounded, never cartoonish, and never borrowed from another messenger.

## The mark: Sealed note

A speech bubble whose top carries an envelope flap. Where the flap folds to
its point, a pear-yellow seal closes it: a private note, sealed, that is
still a conversation. The bubble is cream on an ink tile.

| File | Use |
|---|---|
| `assets/brand/logo.svg` | The app icon: cream bubble, ink flap, pear seal on the ink tile (`#12161C`, corner radius 116 of 512). |
| `assets/brand/mark.svg` | The mark alone, as one ink even-odd silhouette (flap band and seal ring cut out, seal disc solid). Android monochrome and notification icons are this shape. |
| `website/assets/og.png` | Social preview (1200×630): paper, the icon, the name in Chillax. |

Geometry (512 viewBox): the bubble is the path in `logo.svg`; the flap is the
polyline 150,160 → 256,236 → 362,160 in ink, 24 wide with round caps and
joins; the seal is a circle at 256,236, radius 30, pear fill, 8 ink stroke.
The mark sits inside 100–412 on both axes.

Every platform icon (Android adaptive, monochrome and notification, legacy
PNGs, iOS, macOS, Windows, web, website favicon and social preview, the PNGs
in `assets/brand`) is generated from these two files by
`tools/make_icons.py` (`pip install cairosvg pillow`). Change the SVGs, then
run the script; don't edit the PNGs by hand. Android vectors get the flap as
a plain outline, with no strokes.

**Wordmark.** "Securely Hello" in Chillax Semibold, sentence case, ink. No
styled or coloured word, no tagline lock-up.

**Do**

- Keep clear space of at least a quarter of the icon's width around it.
- Use the cream-on-ink icon as is, or the ink silhouette on paper
  (`#F7F5EC`), or the paper silhouette on ink.
- Keep it at 24 px or larger (16 px only as a favicon).

**Don't**

- Use a gradient, a glow or a shadow on or behind the mark.
- Recolour the bubble, the flap or the seal, outline the mark, or rotate it.
- Separate the seal from the flap, or use the flap or the seal alone.
- Put the tile on a busy background.

## Colour

Paper is the light theme, Night the dark one. Tokens live in
`lib/shared/theme/app_palette.dart`; screens use `context.palette`, never raw
colours. Hue never changes between themes, only lightness, to pass contrast.

| Token | Paper (light) | Night (dark) | Use |
|---|---|---|---|
| Background | `#F7F5EC` | `#0B1015` | Screens |
| Chat background | `#F0EDE0` | `#10151B` | Behind messages |
| Surface | `#FCFBF6` | `#151A21` | Cards, bars, sheets |
| Elevated | `#FCFBF6` | `#1E252D` | Dialogs, menus |
| Input fill | `#F0EDE0` | `#1E252D` | Fields |
| Border / divider | `#D7D4C9` / `#E6E1D1` | `#2D333B` / `#222830` | 1 px rules |
| Text primary | `#12161C` | `#F1EFE6` | Names, messages |
| Text secondary | `#3C424A` | `#C7C4BA` | Supporting text |
| Text muted | `#565B63` | `#999FA7` | Times, hints |
| Accent | `#0064BE` | `#F7D21A` | Controls and text in the colour scheme; blue on paper, pear on night |
| Link | `#0064BE` | `#60AAF3` | Links |
| Brand (pear) / on brand | `#F7D21A` / `#12161C` | same | Primary buttons, FAB, selected pill, badges |
| Ledge | `#C9A000` | `#C9A000` | The 4 px edge under pear buttons |
| Outgoing bubble | `#F7D21A`, text `#12161C`, meta `#4A4420` | `#E9C619`, same | Your messages |
| Incoming bubble | `#FCFBF6` + 1 px `#D7D4C9`, text `#12161C`, meta `#565B63` | `#1E252D`, text `#F1EFE6`, meta `#999FA7` | Their messages |
| Read ticks | `#0050A0` | `#12161C` | On the outgoing bubble |
| Story ring | `#FF5E63` | `#FF7979` | Unseen stories; the one loud colour |
| Online / success | `#1E9E5A` / `#00713E` | `#69D98D` | Online, success, answer a call |
| Danger | `#BE222A` | `#FB817F` | Destructive actions, missed calls |
| Warning | `#8A5A00` | `#F7D21A` | Cautions |

Avatars are drawn from pear, coral, blue, mint, kraft `#A9773F` and sugar
`#C9DDF0`, with ink initials on the light ones.

Contrast is checked in `test/palette_contrast_test.dart`: every text token is
at least 4.5:1 on background and surface, accent, online, danger and read
ticks at least 3:1, brand text at least 4.5:1 on pear.

On paper, pear is a fill and never text or a thin line on cream: it only
appears behind ink.

## Type

| Face | Use |
|---|---|
| Chillax 600 | Display, titles, names, buttons, wordmark |
| Chillax 500 | Tab labels |
| Inter 400 / 500 | Body text and messages |
| Source Code Pro | Safety numbers and codes |

Scale: 12, 14, 16, 19, 23, 28, 34. Headings track −0.02 em. Sentence case
everywhere, no uppercase labels. Chillax (ITF Free Font License, Fontshare)
and Inter, Source Code Pro (SIL Open Font License) ship with the app
(`assets/fonts`) and the app never fetches fonts from the network. Hindi and
Gujarati use the phone's own fonts.

## Shape, depth and motion

- **Rounded.** Radii: small 10, input 14, control 16, card and sheet 24,
  onboarding 32, pill. Bubbles use 20, with 6 on grouped corners.
- **Paper depth.** On paper, cards, sheets and the FAB carry a hard-ish paper
  shadow: (1.5, 2.5) blur 1.5 plus (6, 14) blur 16, ink at 10–13 %. On Night,
  depth is lightness steps, not shadows.
- **Controls.** Pear buttons are 52 dp tall with an ink label and an optional
  4 px ledge. Selected chips are ink with paper text; unselected are card
  with a 1 px rule.
- **Motion.** 120, 200 and 320 ms with a snap curve `(0.22, 1, 0.36, 1)`. A
  spring `(0.34, 1.56, 0.64, 1)` only on the primary button and FAB press.
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
