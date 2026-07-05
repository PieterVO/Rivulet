# Now Playing "The Final" (3a) Rail — Design Spec

Date: 2026-07-04
Branch: `feature/nowplaying-redesign` (supersedes the 2a focus-card chrome; builds on its behavior layer)
Design source: `design_handoff_3a_now_playing/` (README + 4 screenshots; option **3a only**)

## Goal

Re-frame the player chrome around a single bottom **glass rail** (metadata +
five round buttons + scrubber in one bar), with **floating glass panels**
above the rail as the one grammar for CC / audio / info / Up Next, a
**timeline-first scrub state**, and the existing watery loading spinner
rehomed to screen center. The 2a behavior layer survives wholesale: BIF
filmstrip + chapter segments, shuttle, replay, markers, Up Next data +
`playEpisode`, ambient pause, live tech stats, `applyChromeVisibility`
single-writer.

User decisions folded in (2026-07-04):
- Up Next is a **fifth rail button**, not a persistent floating card; all
  four content panels share one presenter/style.
- Loading keeps the current watery spinner animation (rotation + shimmer +
  slosh), placed per 3a: centered, 110pt, label beneath.

## Approach (decided)

Evolve in place (approach A). `PlayerContainerViewController` stays host;
`PlayerProgressBarView` is kept (3a scrub reskin); new `PlayerRailView` and
a shared `PlayerRailPanelView` presenter; `PlayerFocusCardView` retires with
its salvageable children (`CardTrackListView`, `CardInfoView`,
`IrisSpinnerView`) extracted to their own files; `PlayerUpNextPanelView`
slims to episode-list panel content. Buildable after every task.

All values are 1080p points from the handoff README.

## Components

### 1. Rail — `PlayerRailView` (new)

- Frame: `left 90 / right 90 / bottom 84`; radius 32 continuous; padding
  `34 v / 42 h`; glass `rgba(18,20,26,.5)` tint over blur (UIGlassEffect on
  tvOS 26 / UIBlurEffect(.dark) fallback), border 1pt `white@0.1`, shadow
  `0 30 70 -20 black@0.6`.
- Top row (`space-between`, gap 32):
  - **Metadata block** (left): eyebrow `Severance · S1 E5` 23pt/500
    `white@0.66`; title 38pt/700 tracking −0.01em, single line; meta row
    (gap 14, 20pt `white@0.55`): rating chip (17pt, 1pt border `white@0.28`,
    padding 2/9, radius 6) · runtime · `·` divider @0.4 · audio format.
  - **Control cluster** (right, gap 20): five 74pt round buttons
    (`TransportControlButton`, bg `white@0.1`, border 1pt `white@0.12`):
    `↺15` skip-back · `CC` subtitles (long-press = replay, unchanged) ·
    audio (`waveform`) · info (`info.circle`) · **Up Next**
    (`list.and.film`; hidden for movies/Live TV or when `upNextEpisodes`
    is empty).
- Scrubber row inside the rail below the top row (top-row ↔ scrubber gap
  30): the existing `PlayerProgressBarView` remains a **container child**
  constrained into the rail's lower region (leading/trailing = rail
  padding insets; its times row bottom = rail bottom padding). Rail is the
  glass backdrop + top row only; the bar keeps its own view so all
  behavior (shuttle, markers, BIF, skeleton) survives unmoved.
- Scrubber rest skin: track 10pt radius 6 `white@0.16`; accent-gradient
  fill (existing `AccentGradientView`); knob 26pt white circle, ring 6pt
  `white@0.14` + drop shadow; times 22pt tabular below (elapsed
  `white@0.82`, remaining `white@0.55`). Ends-at label kept.
- `setPaused(_:)` on the rail dims the knob/fill (existing
  `setPausedDim`) — the paused indicator itself is a container overlay,
  not part of the rail.

### 2. Panels — `PlayerRailPanelView` (new, one presenter for all four)

- One glass panel style: width 452 (info 480), max height 560, radius 20
  continuous, glass `rgba(16,18,24,.5)` + blur, teal ring border 1pt
  `rgba(143,233,212,.5)`, halo `0 0 0 3 rgba(143,233,212,.18)` + drop
  shadow. Positioned **above the rail**, trailing-aligned toward the
  opening button (clamped to the rail's trailing inset), bottom = rail top
  − 24.
- Contents (existing views, extracted to their own files):
  - Subtitles / Audio → `CardTrackListView` (unchanged selection wiring).
  - Info → `CardInfoView` (live tech stats tick preserved).
  - Up Next → `PlayerUpNextPanelView` content: `UP NEXT · SEASON <n>`
    header + season episode list (existing rows, watched / now-playing /
    up-next / future states, auto-centered on current, select →
    `vm.playEpisode`).
- Behavior: press a rail button → panel presents (fade/rise 12pt), focus
  moves into it (initial target: selected track row / up-next row);
  focus is **fenced** inside while open; selection or Menu closes it and
  returns focus to the opening button. Opening another panel swaps
  contents in place. Panels hide with the chrome (scrub / ambient / hide).
- Container unwind order regains the panel step: **panel open → close
  panel** → controls-focus exit → controls hide → dismiss (after the
  existing intro-countdown / post-video / scrub-cancel steps).

### 3. Scrubbing — timeline-first (`PlayerProgressBarView` reskin)

Entering seek mode fades the rail glass + top row + any open panel; the
timeline stands alone at `left 96 / right 96`. The bar's leading/trailing
container constraints animate from the rail insets (90 + 42 = 132) to the
timeline insets (96) on scrub entry and back on exit, inside the bar's
existing single animation block — the strip otherwise grows in place at
the same bottom band:

- Ribbon: 130pt tall, radius 14, chapter-proportional BIF segments with
  6pt gaps (existing `ChapterSegmentLayout`); played dim overlay
  (`black@0.5 → 0.1` to the playhead, inset trailing hairline
  `white@0.15`); 2pt `white@0.2` chapter ticks in the gaps.
- Playhead: 8pt wide white **bar**, radius 6, extending 14pt above and
  below the ribbon, glow `0 0 0 4 black@0.4` + `0 0 26 rgba(180,205,255,.6)`.
  (Replaces the 2a thread + tall-handle morph — the compact knob is
  hidden entirely while the ribbon is open.)
- Progress line: 5pt strip pinned to the ribbon bottom — `white@0.12`
  track, accent-gradient fill to the seek position.
- **Oversized readout** centered above the playhead (clamped on-screen):
  chapter eyebrow `CHAPTER 3 · THE BREAK ROOM` 16pt uppercase tracking
  .12em `white@0.5` (omitted when no named chapter), timecode 50pt/700
  tabular white. Replaces the 2a chip; the small time callout goes away
  (the readout is the callout). Ends-at label hidden while ribbon open.
- Times row below the ribbon: 22pt tabular (seek time / remaining).
- Kept: live-position ghost line, marker band, wheel ring/dot, shuttle
  grammar + step label, chapter up-press snap, no-BIF single-thumbnail
  fallback (unchanged compact-scrub look), reset on `itemGeneration`.

### 4. Paused

- Rail does **not** collapse (3a intent: paused ≈ controls-visible).
- Container overlay top-left (`top 44 / left 64`): two 7×24 white bars
  (gap 6) + `Paused · <m>m left` 22pt `white@0.6` (remaining from
  duration − currentTime).
- Flat `black@0.28` dim over the video (container-level, under the rail).
- Scrubber fill/knob dimmed (existing `setPausedDim`).
- Ambient pause layering unchanged: after the existing idle delay,
  `pausePresentation` tiers fade ALL chrome (rail, panels, indicator) to
  the full-res backdrop + logo; input restores.

### 5. Loading

- Watery spinner kept exactly (rotation 1.4s + shimmer 2.3s + slosh 3.7s,
  cyclic palette): `IrisSpinnerView` parameterized to **110pt** (ring
  stroke 9pt), centered at `(50%, 42%)` of the screen; label beneath
  (gap 28): `LOADING · <quality>` (e.g. `4K DOLBY VISION`; fallback
  `LOADING`) 22pt uppercase tracking .14em `white@0.5`.
- Rail shows the metadata block only — control cluster hidden, no panels,
  Up Next button hidden.
- Scrubber skeleton: flat track `white@0.09` + **shimmer sweep** (40%-wide
  moving highlight `white@0.22`, ~1.8s loop; the one allowed extra
  animation — it lives in skeleton mode only, never concurrent with the
  strip morph), times `--:--` `white@0.22`.
- The in-card loading panel (`CardLoadingView`) and its skeleton bars are
  retired with the card; construction tests move to the spinner + rail
  loading state.
- Loading → playing/paused must not shift the metadata text (same rail
  geometry in every state).

### 6. Focus map

- Surfacing chrome lands on the control cluster (last-focused button,
  default `↺15`).
- Left/Right walk the five buttons; Down → scrubber (seek mode); Up from
  the cluster: nothing (panels are press-driven). The 2a card↔panel focus
  guide is deleted — the reachability problem no longer exists.
- Panel open: focus fenced inside the panel; Menu/selection closes and
  restores focus to the opening button.
- Menu unwind: intro-countdown → post-video → scrub-cancel → open panel →
  controls-focus exit → controls hide → dismiss.
- `applyChromeVisibility` stays the sole alpha writer; tiers become:
  - `chromeVisible` (showControls || isScrubbing, and not ambient) →
    scrim, progress bar.
  - `railVisible` = chromeVisible && !isScrubbing → rail glass + top row,
    pause indicator.
  - `panelVisible` = railVisible && panel open (panel also force-closed on
    scrub start / ambient).
  - Loading additionally hides the cluster and blocks panels.

## Retirements & file moves

- Delete: `PlayerFocusCardView.swift` (card, modes, `CardLoadingView`),
  the card↔panel `UIFocusGuide`, `PlayerUpNextPanelView`'s collapsed-card
  chrome.
- Extract to own files (content unchanged): `CardTrackListView.swift`
  (+ `CardTrackRowButton`), `CardInfoView.swift`, `IrisSpinnerView.swift`
  (gains a diameter/stroke parameter).
- `PlayerUpNextPanelView.swift` becomes the episode-list panel content
  (header + rows + states + select), hosted by `PlayerRailPanelView`.
- Docs: CLAUDE.md + `Docs/RIVULET_PLAYER.md` player-chrome references
  updated to the rail/panels naming.

## Testing & verification

- Keep: `ChapterSegmentLayoutTests`, `UpNextRowStateTests`. Replace
  `CardLoadingViewTests` with construction+layout tests for
  `IrisSpinnerView` (110pt parameterization, ring stays circular) and the
  rail's loading state (metadata-only, skeleton on).
- Build to the tvOS simulator (concrete destination, scratch
  `-derivedDataPath`) after every task; commits are **path-limited**
  (`git commit -- <files>`) — another workstream shares this repo's index.
- No regression in: shuttle rates, replay long-press, marker skip pill,
  ambient pause tiers, BIF reset on episode change, up-next season data.
- Final: user walk-through on the simulator (states 1–4, five buttons,
  panel grammar, timeline scrub, movie hides Up Next button).

## Out of scope

- Skip pill redesign (stays the floating element it is today), post-video
  flow, episode wheel (superseded), trivia/insights (still deferred),
  Live TV grid, any SwiftUI chrome.
