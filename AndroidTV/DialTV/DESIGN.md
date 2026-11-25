# Dial for TV: design research and decisions

Dial TV is its own app (own branch, own module). It shares Dial's data and playback code (Jellyfin, genres, mixtapes,
queue sharing, remote control) and nothing else: the screens are designed for a TV, not stretched from the phone.

## What the sources say

**Verified, from the Android TV design documentation (developer.android.com/design/ui/tv)**

- *10-foot UI.* People sit about 3 m (10 ft) from the screen and lean back. Text and targets must be large; limit
  reading. Complex layouts and controls are a bad fit.
- *D-pad first.* Navigation is up, down, left, right and select. Every press needs instant, distinct feedback, so the
  focused item must always be unmistakable. (No touch, no hover.)
- *Shared device.* A TV is communal: don't show personal data without a way to hide it.
- *Cards.* Three aspect ratios: 16:9 (the default, for wide art), 1:1 (people, logos, **album covers**), 2:3 (to break up
  a grid). The design canvas is 960 x 540 dp. Content width 844 dp (58 dp side margins), 20 dp spacing between cards:
  1 card 844 dp, 2 cards 412 dp, 3 cards 268 dp, 4 cards 196 dp, 5 cards 124 dp. A card's text block is as wide as its
  image. Text on top of an image needs a dark scrim.
- *Navigation drawer.* Left rail, 3 to 7 destinations (5 to 6 recommended), each with an icon and a short label; collapsed
  to icons only, expanded on focus. Standard drawer pushes content aside; modal drawer overlays it with a scrim. App logo
  at the top, up to three actions (settings, profile) at the bottom. Never mix items with and without icons.
- *Typography.* Roboto is the TV default; use larger sizes than phones; avoid decorative fonts; thin weights are not
  legible at a distance. Roles: Display (screen heading only), Headline (carousel and immersive headings), Title (cards,
  lists), Body (reading), Label (buttons, captions).
- *Immersive list.* A row of cards under a large preview of the focused item (16:9 background, subject toward the top
  right, a scrim so text stays readable); details appear as focus moves. Google's own focus treatment is a 1.1 scale, a
  border and elevation.

**From memory, not fetched (the fetch tool failed on these pages), treat as unverified**

- *tvOS (Apple Music, Apple TV).* 1920 x 1080 pt canvas; safe area about 90 pt left and right, 60 pt top and bottom;
  focus lifts the item with parallax and a soft shadow; Now Playing is left-aligned with the cover large on one side and
  lyrics or the queue on the other; typography starts around 29 pt for body and 38 to 76 pt for titles.
- *Spotify and Plex on TV.* A narrow left rail for navigation; a large "now playing" hero with a blurred cover backdrop;
  rows of covers underneath; the player is a full-screen page with the cover on the left and the queue on the right.

**Verified, from your Spotify TV screenshots (1920 x 1080, so 2 px = 1 dp on the 960 x 540 canvas)**

- *Top bar, not a side rail.* A centered navigation row (Home, Search, Your Library, each an icon plus a label) with the
  **now-playing chip at the far left** (cover, title, artist, play button) and the profile at the far right. Side margins
  are 96 px (48 dp); the bar sits about 36 dp from the top.
- *Home is a stage.* A full-bleed backdrop of the focused item fades to black at the bottom; a big title and one line of
  metadata ("Luna Li, Album, 13 songs") sit at the left over it. Below it a 4-column x 2-row grid of **quick-access wide
  cards** (a square cover and one title, 204 x 48 dp), then rows with a plain heading ("Made for you") over covers about
  106 dp wide (8 visible), titles inside or under the cover.
- *Focus is a white outline* (about 2 dp) on a card, with no scaling and no motion.
- *The player is its own page.* Backdrop of the cover, large title with a small cover beside it, a thin progress bar with
  elapsed and remaining time, a row of round buttons under it (play, next, shuffle, cast), and "Queue" and other options as
  pills on the right. It is not the phone player enlarged.

## Decisions for Dial TV

| Topic | Decision |
|---|---|
| Canvas | Design at 960 x 540 dp; all sizes in dp/sp so it scales to 1080p and 4K |
| Safe area | 58 dp left and right, 32 dp top and bottom (a little more than the 5% overscan rule) |
| Navigation | **A centered top bar** (Home, Radio, Library, Search: icon plus label), as on Spotify's TV app. Left: the now-playing chip (cover, title, artist, play/pause; opens the player). Right: Settings. The bar is always visible; moving up from any row reaches it. No side drawer |
| Focus | Accent 3 dp border and a lighter surface; **no scaling** (it overlapped neighbours and got clipped on the phone-style layout, and you asked for none); focus never moves unexpectedly |
| Home | A stage: the backdrop and big title of whatever is focused (artist backdrop, or the cover enlarged with a scrim), then a 4 x 2 quick-access grid (recently played albums, mixtapes, favorites), then rows of covers |
| Covers | 1:1, 140 dp wide (about 6 visible), title and subtitle under the cover, one line each |
| Type | Roboto. Display 44 sp (screen title), Headline 28 sp, Title 20 sp, Body 16 sp, Label 14 sp; nothing under 14 sp; weights 500 and up |
| Text | At most one line for card subtitles; no paragraphs; long lists use rows, not walls of text |
| Player | A different layout from the phone's: full-screen cover backdrop with a scrim; at the left a title (Display) with the small cover, artist and album under it; across the bottom a thin progress bar with times and a row of round buttons (previous, play/pause, next, shuffle, repeat, devices, favorite) with Queue and Lyrics as pills on the right. Queue and lyrics open as a panel from the right edge |
| Sign-in | Server discovery first, then **Quick Connect** (a code to approve from a phone); typing is the fallback |
| Performance | Release builds only; no blur; images sized to what's drawn; heavy work off the main thread; no work on first frame beyond the visible rows |
