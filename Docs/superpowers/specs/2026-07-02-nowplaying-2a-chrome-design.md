# Now Playing "The Final" (2a) Chrome — Design Spec

Date: 2026-07-02
Branch: `feature/nowplaying-redesign` (builds on the completed behavior-layer redesign, final commit `1f7e8cf`)
Design source: `Docs/design_handoff_now_playing/` (README + annotated screenshots; direction **2a only**)

## Goal

Restructure the player overlay chrome to the 2a layout: a persistent bottom-left
**focus card**, a right-side **Up Next panel**, and a **height-locked scrubber**,
carrying four states (Controls / Scrubbing / Paused / Loading) in one layout.
All existing behavior shipped on this branch (BIF filmstrip, shuttle grammar,
replay, ambient pause, tech stats, marker skips) survives and is rehomed —
this is a chrome restructure, not a feature cut.

## Approach (decided)

Restructure in place. `PlayerContainerViewController` stays the host;
`PlayerProgressBarView` is kept and restyled (it owns the filmstrip/shuttle
work); two new views are built (`PlayerFocusCardView`, `PlayerUpNextPanelView`);
`PlayerTransportBarView` and the anchored popup system are deleted at the end.
The player must stay buildable after every task.

All pixel values below are 1080p points, taken directly from the handoff README.

## Components

### 1. Focus card — `PlayerFocusCardView` (new)

- Frame: `left 96`, `width 720`, vertical band `top 280 / bottom 280` (height 520).
  **Constant in every state** — never moves, never resizes; only inner content swaps
  (crossfade).
- Container: `UIVisualEffectView` dark blur with fill tint `rgba(16,18,24,.42)`
  (loading `.40`), `cornerRadius 34` + `.continuous`, border 1pt `white@0.1`,
  padding `46 48`. Card/panel shadow per token sheet.
- Layout: vertical column — metadata block top, flexible spacer, controls row
  pinned bottom.

**Card modes** (new published `cardMode` on the view model or card-local state):

| Mode | Content |
|---|---|
| `metadata` (default) | Series line (`Severance · S1 E5`, 23pt/500/white@0.6) → title (48pt/700, tracking −0.015em, line-height 1.05) → meta row (rating badge · duration · audio format) → spacer → controls row |
| `subtitleTracks` / `audioTracks` | Track list rows salvaged from `PlayerTrackPopupView` (same selection wiring to the view model). Menu → back to `metadata`. |
| `info` | Info + live tech sheet content salvaged from `PlayerInfoPopupView`, including `AetherLiveStats`. Menu → back to `metadata`. |
| `loading` | Iris spinner (64pt conic accent-gradient ring, masked to a ring, 1.4s linear rotation) beside `Loading · <series> · <ep>` (23pt, white@0.55); title below; two skeleton bars (22pt tall, 60%/40% wide, white@0.08/0.06). |

Paused is `metadata` plus a `⏸ Paused` indicator line above the series line
(not a separate mode).

**Controls row**: primary white pill (`Resume`/`Pause`, bg `#ffffff`, text
`#06070b`, glow `rgba(180,205,255,.28)`) + four 72×72 round buttons
(bg `white@0.1`, border 1pt `white@0.12`): `↺15` skip-back, `CC` subtitles,
audio, **info** (info is an addition to the three shown in the mock — decided).
Focus styling per existing `TransportControlButton` behavior (white fill +
scale on focus). Replay stays on **CC long-press**.

The anchored popup system (`AnchoredPopupPresenting`, `PlayerTrackPopupView`,
`PlayerInfoPopupView`) is **retired**; their content rendering is salvaged into
card modes, then the files and the container's popup focus plumbing are deleted.

### 2. Up Next panel — `PlayerUpNextPanelView` (new)

- Expanded frame: `right 80`, band `top 280 / bottom 280`, `width 470`,
  padding `26 24`. Glass `rgba(14,17,23,.55)`; focus accent border
  `rgba(143,233,212,.55)` with ring `rgba(143,233,212,.22)`.
- Collapsed (unfocused): a single row — the up-next episode — vertically
  centered at the right edge.
- Expanded (focus arrives from the card): header `UP NEXT · SEASON <n>`,
  scrollable episode list.
- Data: **all episodes of the playing season** (existing
  `getChildren(parentRatingKey)` path), auto-centered on the current episode.
  Row states: `watched` / `nowPlaying` (+ progress tick) / `upNext` / future.
  Row styling per token sheet (focused row: bg `white@0.16`, border
  `white@0.25`, scale 1.02 — matches the app's glass grammar).
  Season finale: the next season's opener is appended as the up-next row via
  the view model's existing up-next resolution.
- Hidden entirely for movies and Live TV; hidden while scrubbing.
- Select on a row plays that episode through the existing episode-change path
  (already resets filmstrip, replay window, markers, `itemGeneration`).
- Fetch failure → panel stays hidden (no error UI).
- **Supersedes** the reserved Browse slot / deferred episode wheel; the hidden
  Browse button is removed.

### 3. Scrubber — `PlayerProgressBarView` (kept, restyled)

Locked geometry in every state: `left 96 / right 96 / bottom 140`.

- Track: 10pt tall, radius 6, `white@0.16`. Played fill: accent gradient
  `#7fb8ff → #b9a3ff 45% → #ffce93 80% → #8fe9d4`, radius 6.
- Handle: 24×24 white circle, ring `6pt white@0.14`, drop shadow. While
  scrubbing: morphs to a **14×46 rounded bar** (radius 8, ring `5pt white@0.16`).
- Times below (16pt gap, space-between), 22pt tabular-nums: elapsed
  `white@0.82`, remaining (`-MM:SS`) `white@0.55`.
- **Filmstrip (scrubbing)**: 120pt tall, radius 12, directly above the scrubber.
  Restructured into **chapter-proportional segments with 6px gaps**, each
  segment tiled with its chapter's **BIF frames** (existing pipeline — real
  previews inside 2a's chapter geometry). Played-side dim overlay
  (`rgba(0,0,0,.5) → .08` left→playhead), 2pt `white@0.22` ticks at chapter
  boundaries, chapter chip above the playhead (`CH 3 · BREAK ROOM`, 17pt
  uppercase, tracking 0.1em, on `black@0.55` pill radius 8), 3pt white
  playhead thread fading through card and scrubber. No chapters → single
  continuous segment (current behavior). The existing time callout and
  ends-at label are **kept** alongside the chip.
- **Loading skeleton**: empty track `white@0.08`, times `--:--` at
  `white@0.22`, same locked position (keeps vertical rhythm on load → play).
- All existing behavior preserved: shuttle grammar + jog ring, chapter
  up-press snap, marker band, BIF reset on `itemGeneration`.

### 4. Skip pill & scrim

- The marker skip pill stays its **own floating element**, unchanged behavior,
  independent of the card.
- The old bottom transport scrim is replaced by the 2a left-readability scrim:
  horizontal `rgba(0,0,0,.8) → .2 @46% → transparent @66%`.

## States

| State | Card | Scrubber | Up Next |
|---|---|---|---|
| Controls | metadata + controls row | styled, circle handle | visible (collapsed/expanded) |
| Scrubbing | metadata (unchanged) | filmstrip + bar handle + chip + thread | hidden |
| Paused | metadata + paused line | styled, dimmed fill | visible |
| Loading | loading mode (spinner + skeletons) | skeleton | hidden |

Paused → ambient: unchanged from the shipped ambient-pause flow — 4s idle fades
the whole chrome (card, scrubber, panel) to the full-res backdrop + logo; any
input restores it. Loading shows on initial load and on episode/route changes.

## Focus map

Evolves the existing two-door model:

- Surfacing controls (any direction press with chrome hidden) lands on the
  card's **Resume** button. (Deliberate deviation from the handoff's "Down
  focuses the scrubber directly": a single landing point avoids dropping the
  user straight into seek mode; the scrubber is one Down away.)
- **Down** from the card → scrubber (seek mode; filmstrip appears).
- **Right** from the card → Up Next panel (expands; Left/Menu collapses back
  to the card).
- Card modes fence focus inside the card while a track list / info sheet is up.
- Menu unwind order: in-card panel → `metadata` → controls hidden → player
  dismiss. (The container's popup unwind step disappears with the popups.)

State plumbing: existing `isScrubbing`, `playbackState`, pause idle timer, and
`controlsFocusActive` drive the states; new published state is limited to
`cardMode` and `upNextEpisodes` (+ collapsed/expanded panel focus).

## Housekeeping (first task) & deletions (last task)

1. **First**: strip the `[FocusDbg]` NSLogs from the working tree; keep the two
   real fixes (keyboard/GameController input-mirror swallowing in
   `RemoteInputHandler`; Menu ended-phase swallow in
   `PlayerContainerViewController`); commit. The popup fence fixes are dropped
   (popups are being deleted).
2. **Last**: delete `PlayerTransportBarView`, `PlayerTrackPopupView`,
   `PlayerInfoPopupView`, `AnchoredPopupPresenting`, and popup-related
   container focus code. Grep for dangling references.

## Testing & verification

- Build for tvOS simulator (concrete arm64 destination, scratch
  `-derivedDataPath`) after every task; install to sim per workflow preference.
- No regression in shipped behaviors: shuttle rates, replay revert, ambient
  pause, marker skips, jog ring, BIF filmstrip reset on episode change.
- Device checklist (pre-merge, extends the existing one): focus walk
  (card ↔ scrubber ↔ Up Next), card mode swaps + Menu unwind, Up Next select
  starts episode, loading skeleton on cold start and episode advance, paused
  ambient still fires, filmstrip segments on chaptered content (183532),
  chip + thread rendering.

## Out of scope

- Episode wheel / arc rail (superseded by Up Next panel), trivia/insights
  (still deferred), gapless Up Next (AVQueuePlayer migration), any SwiftUI
  rewrite of player chrome, Live TV grid UI.
