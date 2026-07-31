# Subtitle overlay: SwiftUI to UIKit port

Status: **implemented**. Follows PR #274 (merged `66564b7`). Builds clean,
SwiftLint 0 violations, 851 tests pass. NOT yet verified on hardware — see
Verification below, which is the remaining work.

One correction the implementation forced, recorded because the plan was wrong:
**`SubtitleParser.swift` is not dead and was not deleted.** `VTTParser` is live,
parsing `text/mcf+vtt` for the content filter (`ContentFilterParsers.parse`).
Only `SRTParser`, `ASSParser` and `SubtitleFormat` in that file lack a
production caller, and their own unit test keeps them compiled. The original
delete list said the whole file went, which the build caught immediately. Check
for the TYPE, not the filename, before deleting anything in this area.
`BitmapSubtitleCue` / `BitmapSubtitleRect` genuinely were orphaned and are gone.

## Goal

One UIKit subtitle overlay, fed by the engine cue model, mounted as a plain
subview in `PlayerContainerViewController` and `LiveTVAetherPlayerViewController`.
Delete both SwiftUI overlays and the dead RPlayer sidecar pipeline behind them.

## Why

Three hacks in the current overlay exist only because it is SwiftUI:

1. **Outline.** SwiftUI `Text` has no stroke, so the caption outline draws the
   whole string 8 times at offsets, and since #274 each of those copies resolves
   per-run fonts. `NSAttributedString` with a negative `.strokeWidth` gives
   stroke and fill in a single pass.
2. **Placement.** A text box cannot be measured without a layout pass, so
   `placedCue` estimates half the box as `pointSize * 0.7`. That is exact for a
   one-line cue and wrong for a two-line one, which both mis-anchors it and
   softens the floor clamp by up to `0.6 * pointSize`. `boundingRect` measures
   it for real.
3. **Hosting.** `LiveTVAetherPlayerViewController` wraps the overlay in a
   `UIHostingController` and calls `rebuildSubtitleOverlay(animated:)` from five
   sites to tear down and rebuild the root view, because nothing observes the
   player from SwiftUI. A UIView subview needs none of it.

Separately, the `hls`-route overlay is dead and has been since `390ebec` removed
RPlayer's VOD branches. Nothing calls any `SubtitleManager` cue-ingestion method,
so its track is permanently empty. Keeping two renderers in sync is work spent on
a view that never draws.

## Delete

Re-verify each has no callers at port time, then remove:

- `Services/Plex/Playback/Subtitles/SubtitleOverlayView.swift` (dead renderer)
- `Services/Plex/Playback/Subtitles/SubtitleManager.swift` (no cue source)
- `Services/Plex/Playback/Subtitles/SubtitleParser.swift` and its test (only the
  test references it)
- `Services/Plex/Playback/Subtitles/SubtitleClockSyncController.swift` (ticks an
  empty track)
- `BitmapSubtitleRectView`
- `Views/Player/Aether/AetherSubtitleOverlayView.swift` (replaced)
- `subtitleHostingController` and `rebuildSubtitleOverlay` in
  `LiveTVAetherPlayerViewController`
- The `subtitleManager` property and its `delaySeconds` writes in
  `UniversalPlayerViewModel`

## Port verbatim

These were tuned by eye against AVPlayer on a real Apple TV across three
attempts (#258, #259, #274). Carry them across. Do not re-derive them.

| Constant | Value | Meaning |
|---|---|---|
| `fontHeightFraction` | 0.0529 | point size as a fraction of PRESENTATION height, not picture height |
| `assumedVideoHeight` | 1080 | fallback for a zero-height layout pass |
| `cornerRadiusRatio` | 0.25 | 5pt at the smallest setting (20pt type) |
| `paddingHRatio` / `paddingVRatio` | 0.30 / 0.075 | box hug, tuned independently of radius |
| `bottomMarginFraction` | 0.06 | of PICTURE height, shared with the rail floor |
| `railTopFromScreenBottom` | 344 | `PlayerRailView.railHeight` 260 + 84 inset |
| `sideSafeFraction` | 0.05 | AVPlayer will not draw to the picture edge |
| `bandTopFraction` | 0.10 | teletext top-band resting anchor |
| `fontScale` clamp | 0.25...4.0 | the old 0.5...2.0 swallowed a real system value of 0.35 |

Semantics worth keeping in comments:

- A WebVTT line position names the box's **top** edge (`line-align: start`), so
  the box hangs down from it. Anchoring the centre sits half a box high.
- ASS numpad grid: rows 7-9 top, 4-6 middle, 1-3 bottom; columns 1/4/7 left,
  2/5/8 centre, 3/6/9 right; 2 is the default.
- Point size comes from presentation height, position from picture height, so a
  2.39:1 film gets the same type size as 16:9 but sits on the image rather than
  in the black bar.
- Read each `CaptionAppearance` Video Override flag immediately after its own
  `MediaAccessibility` call, before the next call overwrites the out-param.

## Fixed by construction

The port removes rather than repairs:

- 8-copy outline and its per-run font resolution
- the `pointSize * 0.7` half-box estimate, and the soft floor clamp for
  multi-line placed cues
- the hosting-controller rebuild plumbing
- caption size diverging by route, since one renderer cannot have two sizes

## Carried over, still open

`bottomMarginFraction = 0.06` yields ~64.8pt resting margin on a full-bleed 16:9
title at 1080. It replaced a fixed 100pt, which `3ca9fea` had raised from 60
after finding that "60 sat visibly too close to the screen edge." Check it on a
television before keeping the number.

## Phases

All four done.

1. `Views/Player/UIKit/CaptionOverlayView.swift`, mounted in
   `PlayerContainerViewController` between the hosting controller and the chrome.
   The lift rides `applyChromeVisibility`'s own `UIView.animate` block, so the
   captions and the rail share one clock rather than two matched timers.
2. Mounted in `LiveTVAetherPlayerViewController`. `subtitleHostingController`,
   `makeOverlayRootView` and `rebuildSubtitleOverlay` are gone, replaced by
   `syncSubtitleOverlay(animated:)` pushing properties. That file no longer
   imports SwiftUI.
3. `SubtitleManager`, `SubtitleClockSyncController`, `BitmapSubtitleCue`,
   `BitmapSubtitleRect` deleted, along with the view model's `subtitleManager`
   and `subtitleClockSync` members and the dead `hls` branch in
   `activeSubtitleTextForFilter`.
4. `AetherSubtitleOverlayView` and the SwiftUI `SubtitleOverlayView` deleted;
   `UniversalPlayerView` no longer renders captions.

`CaptionStyle` and `AetherSubtitleCue.StyledRun` now carry `UIColor`/`UIFont`
instead of SwiftUI `Color`/`Font`. That was not optional: the SwiftLint rule
`swiftui_import_on_uikit_surface` makes `import SwiftUI` an error anywhere under
`Views/**/UIKit/**`, so the overlay could not have referenced a SwiftUI `Color`.

## Verification

Device, not Simulator. The Simulator does not mimic Apple TV for this.

- Subtitle test content: `183665` (best coverage), `209281`, `12974` / `63657`
- Letterboxed film for the picture-rect and margin check
- A teletext or DVB live channel for placed cues and the two-line floor clamp
- Rail up and rail down, plus a scrub, for the lift animation
- System caption size at smallest and largest, to exercise the scale clamp
