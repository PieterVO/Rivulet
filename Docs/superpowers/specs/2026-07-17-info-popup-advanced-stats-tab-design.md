# Info Popup — "Advanced" stats tab (AetherEngine telemetry)

Date: 2026-07-17

## Goal

Add a second tab to the player's Now Playing **Info** popup. The popup opens
on the existing metadata sheet (default, no fetch). Tabbing over to a new
**Advanced** tab surfaces AetherEngine's live "stats for nerds" telemetry
(`engine.diagnostics.liveTelemetry`), which is already sampled at 1 Hz by the
engine but never shown in-app today.

Tab bar reads: **Info | Advanced**.

## Context (what exists today)

- The Info popup is `CardInfoView`
  (`Rivulet/Views/Player/UIKit/CardInfoView.swift`), presented from the player
  rail's Info button via `rail.onInfo` in
  `PlayerContainerViewController` (`presentRailPanel(content:width:from:)`,
  width 560).
- `CardInfoView` shows: Media Info, VIDEO, AUDIO, a small live **PLAYBACK**
  section, SUBTITLES, FILE. The PLAYBACK section is fed by
  `aetherPlayer?.liveStats()` → `AetherLiveStats` (buffer / backend /
  audioBridge only), ticked 1 Hz by a `Timer` tied to window attach/detach.
- The "trivia tabs" whose look we're borrowing are the separate **Insights**
  panel: `InsightsTabBarView` (pill bar) + `InsightsPanelContainerView`
  (tab bar + content + focus/menu plumbing). We copy the *pattern*, not the
  types.
- AetherEngine's richer telemetry is `engine.diagnostics.liveTelemetry`
  (`LiveTelemetry?`), a 1 Hz snapshot the engine **auto-starts** on native
  load (`LiveTelemetrySampler`). Populated while playing *and* paused; nil
  while idle and on the `hls`/AVPlayer-bypass path. Reading it is a pure read —
  no new sampler, no added hang risk beyond the sampler that already runs
  (upstream app-hang issue #134 is orthogonal; it exists whether or not we
  display the numbers).
- `LiveTelemetry` fields (all engine-public):
  - Enthusiast: `instantBitrateMbps?`, `averageBitrateMbps?`,
    `audioBridgeBitrateMbps?`, `observedFps?`, `droppedFrameCount?`,
    `forwardBufferSeconds?`, `cachedBytes?`, `networkThroughputMbps?`,
    `networkTransferredBytes?`, `avSyncGapMs?`
  - Engine diagnostics: `producerRestartCount`, `muxedBytesLifetime`,
    `serverBytesSentLifetime`, `serverRequestCount`, `demuxerBytesFetched`,
    `audioBridgeLiveBytes`, `rssMb`
  - Nils are **path-asymmetric**: e.g. `observedFps` nil on the native/AVPlayer
    path, `droppedFrameCount` / `avSyncGapMs` / `forwardBufferSeconds` nil on
    the software path. Rows self-prune on nil (no placeholder dashes) — exactly
    how `CardInfoView` already omits absent metadata rows.

Scope note: the Info popup lives on the VOD player chrome
(`PlayerContainerViewController`) only. Live TV uses a different path and has
no Info button — out of scope.

## Design

### Structure

`rail.onInfo` presents a new thin container instead of a bare `CardInfoView`:

```
rail.onInfo → PlayerRailPanelView.present(
    content: PlayerInfoTabsView(               // NEW container
        tabBar: InfoTabBarView[Info|Advanced], // NEW sibling pill bar
        info:  CardInfoView,                   // EXISTING, minus PLAYBACK block
        advanced: CardStatsView))              // NEW, lazy on first tab-over
```

New files (all in `Rivulet/Views/Player/UIKit/`):
- `PlayerInfoTabsView.swift` — the container (tab bar + two content views +
  focus/menu plumbing). Sibling to `InsightsPanelContainerView`, simpler (no
  crossfade/actor sub-state).
- `InfoTabBarView.swift` — a dedicated 2-pill bar styled to match
  `InsightsTabPillView`. Own type, **not** a shared subclass and **not** a
  refactor of `InsightsTabBarView` (that bar's own header documents the same
  sibling-over-sharing choice; keep the working trivia panel untouched).
- `CardStatsView.swift` — the Advanced content sheet.

Edited files:
- `CardInfoView.swift` — remove the live PLAYBACK section, its
  `bufferRow`/`backendRow`/`audioBridgeRow` fields, the `Timer` lifecycle, and
  the `liveStatsProvider` parameter. It becomes a pure static metadata sheet.
- `AetherPlayer.swift` — add the detailed-stats accessor (below).
- `PlayerContainerViewController.swift` — `rail.onInfo` builds
  `PlayerInfoTabsView` and passes the advanced-stats provider.

### Tab content

**Info tab** — `CardInfoView` as it is today minus the PLAYBACK block:
Media Info, VIDEO, AUDIO, SUBTITLES, FILE. Static, no timer, no provider. This
is the default tab and requires no fetch, so the popup "loads what we currently
show first."

**Advanced tab** — `CardStatsView`, built lazily on the first tab-over and
ticked 1 Hz **only while it is the visible tab**. Sections (each row omitted
when its source value is nil):
- **DECODE** — Backend, Audio Bridge
- **STREAM** — Video bitrate (instant / avg), Observed FPS, Dropped frames,
  Audio-bridge bitrate
- **BUFFER / NETWORK** — Forward buffer, Cached, Network throughput,
  Transferred, A/V sync gap
- **ENGINE** — Producer restarts, Muxed, Server sent + requests, Demuxer
  fetched, Audio-bridge live bytes, RSS

Formatting reuses the same helpers already in `CardInfoView`
(`formatBitrate`, `formatFileSize`, `formatBufferSeconds`) plus small
additions for Mbps / fps / ms — kept as static helpers so both sheets share
one formatting vocabulary.

### Data plumbing

Keep the view engine-free, matching how `AetherLiveStats` is an app-side
wrapper rather than the engine's own type. Add to `AetherPlayer`:

```swift
struct AetherAdvancedStats {
    // Identity (from engine.activeVideoDecoder / activeAudioDecoder)
    let backend: String?
    let audioBridge: String?
    // Mapped 1:1 from engine.diagnostics.liveTelemetry (nil when idle/hls)
    let instantBitrateMbps: Double?
    let averageBitrateMbps: Double?
    let audioBridgeBitrateMbps: Double?
    let observedFps: Double?
    let droppedFrameCount: Int?
    let forwardBufferSeconds: Double?
    let cachedBytes: Int64?
    let networkThroughputMbps: Double?
    let networkTransferredBytes: Int64?
    let avSyncGapMs: Double?
    let producerRestartCount: Int?
    let muxedBytesLifetime: Int64?
    let serverBytesSentLifetime: Int64?
    let serverRequestCount: Int?
    let demuxerBytesFetched: Int64?
    let audioBridgeLiveBytes: Int?
    let rssMb: Int?
    var isEmpty: Bool { /* all display fields nil */ }
}

func advancedStats() -> AetherAdvancedStats? { … }   // nil if no telemetry yet
```

`CardStatsView` takes a `() -> AetherAdvancedStats?` provider (same shape as
today's `liveStatsProvider`) and refreshes rows in place each tick, rebuilding
the row set if a section's availability flips. The provider closure may itself
return nil transiently (telemetry not yet sampled at popup-open, or the engine
briefly idle); rows self-prune until the first non-nil tick.

Tab-bar visibility is **route-based, decided once at construction** from
whether the advanced provider *closure* is non-nil — the same optional-closure
signal `CardInfoView` already uses (`liveStatsProvider: (() -> …)?`). A non-nil
closure means the aether route (an `AetherPlayer` exists) → **Info + Advanced,
with the tab bar**. A nil closure means the `hls` route (no `AetherPlayer`) →
**only the Info tab, no tab bar** — the popup renders exactly as today.
Visibility deliberately does NOT depend on the first snapshot's content, so a
momentarily-nil telemetry read at open never hides the tab (it would otherwise
flicker in a beat later); a present-but-idle Advanced tab simply shows sparse
rows that fill on the next tick.

### Focus & Menu (tvOS)

Mirror `InsightsPanelContainerView`'s proven plumbing (implementation will use
the `rivulet-tvos-uikit` skill):
- **Down** from a pill → content; **Up** from the content scroll's top edge →
  tab bar. `CardInfoView`/`CardStatsView` expose an `isFocusAtTop()` the
  container consults, and the container drives the cross-boundary move via a
  transient `focusEscapeTarget` + `setNeedsFocusUpdate()` from the common
  ancestor (the focus engine ignores the request otherwise).
- **Left/Right** stays inside the 2-pill bar via `shouldUpdateFocus` veto (same
  as `InsightsTabBarView`).
- **Menu** → dismiss the whole panel from either tab. No sub-state to unwind,
  so the container declines Menu (does not conform to `RailPanelMenuHandling`,
  or conforms and returns `false`) and `PlayerRailPanelView` dismisses.
- Switching tab reveals the target content and re-lands focus on it. The
  Advanced 1 Hz tick starts on first reveal and stops when the panel detaches
  (`window == nil`) or focus tabs back to Info.

### Styling — cohesive with the rest of the app

Explicit requirement: the new surfaces must read as the same app, not a
bolted-on debug overlay. Concretely:

- **Pills** match `InsightsTabPillView` exactly: continuous-corner capsule
  (`cornerRadius = height/2`); rest = clear bg, `white 0.72` label, bold 20pt;
  selected = liquid-glass capsule (`UIGlassEffect(.regular)` on tvOS 26, else
  `.light` blur), white label, heavy weight; focused = opaque `white 0.9` bg,
  black label, heavy weight, `1.05` scale, animated via the focus
  coordinator. Uniform pill width sized to the widest title.
- **Rows / sections** in `CardStatsView` reuse `CardInfoView`'s exact type
  ramp — section label 14pt bold `white 0.5`; `infoRow` label 16pt medium
  `white 0.6` + value 18pt regular white; body 18pt. Same 16pt stack spacing,
  same `InfoScrollView` focus/scroll behavior. Extract the shared row/section
  builders so both sheets are visually identical by construction rather than by
  coincidence.
- **Panel** stays the existing `PlayerRailPanelView` glass host at width 560;
  tab bar sits above the content with `InsightsPanelContainerView`'s 16pt
  spacing. Motion stays within the Design Guide's restraint (subtle scale,
  spring focus) — no new decoration, gradients, or shadows.

## Testing

- Unit-testable, UIKit-free: `AetherAdvancedStats.isEmpty` and the number
  formatters (Mbps / fps / ms / bytes) — table-driven, incl. nil/zero/negative
  clamping (`avSyncGapMs` can be negative; buffer clamps ≥ 0).
- `PlayerInfoTabsView` tab-availability logic: provider present + non-nil →
  two tabs + bar; provider nil / first snapshot empty → Info-only, no bar.
- Follows the existing `InsightsTabBarView.availableTabs`-style pure-function
  test pattern where possible (host-independent decision, then thin UIKit
  wiring).

## Out of scope / non-goals

- No new engine sampler, no upstream AetherEngine change, no gating flag — the
  telemetry already runs; we only read it. (Issue #134 is unaffected.)
- No Live TV Info popup (that surface has no Info button).
- No per-field debug toggle; the ENGINE section ships on by default per the
  agreed "everything, incl. engine internals" depth.
- No persistence of the selected tab across popup opens — always lands on Info.

## Changelog

Add a user-facing line to `WhatsNewView.changelogs` for the current build:
Info popup now has an Advanced tab with live playback stats. No em dashes.
