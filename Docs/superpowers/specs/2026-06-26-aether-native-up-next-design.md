# Aether Native "Up Next" Card — Design

**Date:** 2026-06-26
**Branch:** feature/person-detail-page (current working branch)
**Status:** Approved design, pre-implementation

## Problem

When the **Aether** player finishes a TV episode, it should present an end-of-episode "Up Next" experience, and it should honor Plex intro/credits/commercial markers (skip buttons + auto-skip) the way the other two players do. Today it does neither well:

1. **No real-time marker handling.** `bindAetherPublishers` updates `currentTime` only; it never calls `checkMarkers(at:)`. So on Aether: no skip-intro / skip-credits / skip-ad buttons, no auto-skip, and the post-video trigger falls back to a crude "45s before end" heuristic instead of the real Plex credits marker. (RPlayer and the Apple player both call `checkMarkers(at:)` every time tick.)
2. **No native Up Next card.** The user wants Apple's native look. Aether's natively-playable route renders through a real `AVPlayerViewController` (`AetherPlayerViewController : BaseAVPlayerViewController : AVPlayerViewController`), so Apple's native `AVContentProposal` "Up Next" card is genuinely available there — but it is not wired.

## Goal

On Aether's **natively-playable route**, present Apple's native `AVContentProposal` Up Next card, triggered at the Plex credits marker (with fallbacks), used as **UI + signal only** — accepting the card advances via our existing `playNextEpisode()` so Continue-Watching / scrobble / mark-watched stay intact. As a foundational by-product, wire Aether's time tick to `checkMarkers()` so Aether also gains the intro/credits/ad skip buttons and auto-skip it currently lacks.

## Non-goals (explicitly deferred)

- **Gapless transitions.** Aether's native host is a single `AVPlayer` using `replaceCurrentItem` (no `AVQueuePlayer`), so every episode swap is a ~0.5-1s surface-tear black frame. True gapless requires migrating `NativeAVPlayerHost` to `AVQueuePlayer` — its own future spec. This feature deliberately keeps the existing transition behavior (no regression, no gapless).
- **Native card on the software/DV route.** On that route Aether sets `currentAVPlayer = nil` and renders to `AVSampleBufferDisplayLayer` directly, so there is no `AVPlayer`/`currentItem` to attach a proposal to. That route keeps the existing custom `EpisodeSummaryOverlay`. A future research spike (decoy/stub `AVPlayer`) may unify the look later, but it risks AVKit compositing over the real video and is out of scope here.
- **RPlayer and the Apple player.** No behavior change beyond what is already shared.

## Architecture & integration model

### Dual-path Up Next on Aether (structurally forced, not a compromise)

| Aether route | Has `AVPlayer`? | Up Next presented |
|---|---|---|
| Natively-playable (most H.264/HEVC HLS/MP4) | Yes (`NativeAVPlayerHost.avPlayer`, published as `currentAVPlayer`) | **Apple native `AVContentProposal` card** (new) |
| Software / DV / FFmpeg | No (`currentAVPlayer = nil`, display-layer render) | Existing custom `EpisodeSummaryOverlay` (already wired via `handlePlaybackEnded()`) |

Consequence the user has accepted: a user may see two different Up Next styles across episodes of one show depending on codec (native card on a native episode, custom overlay on a DV episode). Unifying that is the deferred decoy-player spike.

### Control boundary — "UI + signal only"

We set `currentItem.nextContentProposal` purely so AVKit renders its card and fires its delegate callbacks. We do **not** queue a real next `AVPlayerItem`, and we do **not** let `AVPlayerViewController` advance its own queue. On accept we call the host's `playNextEpisode()`, which loads the next episode through Aether's normal path. Rationale: Aether owns its `AVPlayer`'s item lifecycle (reloads, live-rejoin swaps); letting Apple auto-advance would fight that and would sever the progress/scrobble/Continue-Watching reporting chain (re-introducing the exact bug fixed by the recent `.ended` wiring).

## Components & changes

### 1. Wire Aether time → `checkMarkers()` (foundation)
**File:** `Rivulet/Views/Player/UniversalPlayerViewModel.swift`, `bindAetherPublishers(_:)` (~line 1630), `timePublisher` sink (~line 1652).
**Change:** in the time sink, call `self.checkMarkers(at: time)` (mirroring the RPlayer sink at ~line 1178 and the AVPlayer observer at ~line 979), in addition to updating `currentTime`.
**Safety:** Aether ticks at 0.1s (native host) / 0.25s (software host) — both finer than the ~0.5s cadence `checkMarkers` assumes; no throttle change needed.
**Delivers for free:** Aether intro/credits/ad skip buttons + auto-skip (currently entirely absent), and the real credits-marker post-video trigger replacing the 45s heuristic.

### 2. Native Up Next card on `AetherPlayerViewController`
**File:** `Rivulet/Views/Player/AetherPlayerViewController.swift` (class at line 44; existing `currentAVPlayer` bind via `bindPlayerSpecific()` flatMap at ~line 169).
**Changes:**
- Conform to `AVPlayerViewControllerDelegate`; set `self.delegate = self`.
- When the next episode is resolved (see §3) AND a real `currentAVPlayer?.currentItem` exists, build an `AVContentProposal(automaticAcceptanceInterval:title:previewImage:)` from the next episode (title + thumb) and set it on `currentItem.nextContentProposal`.
- Implement delegate callbacks:
  - `playerViewController(_:shouldPresent:)` → return `true` (allow the card).
  - `playerViewController(_:didAccept:)` → call host `playNextEpisode()`; dismiss the proposal UI.
  - `playerViewController(_:didReject:)` → clear the proposal; let the episode end normally (existing `.ended` → `handlePlaybackEnded()` path runs, which on the native route may itself present nothing further since the card already handled Up Next; see §5 reconciliation).

### 3. Host ↔ VC bridge (read next-episode state + accept callback)
**File:** `Rivulet/Views/Player/UniversalPlayerViewModel.swift` (state already present) + `AetherPlayerViewController.swift`.
- The VM already exposes `@Published private(set) var nextEpisode: PlexMetadata?` (line 316) and the methods `fetchNextEpisode()` (3749), `preloadNextEpisode()` (3893, caches the thumb), and `playNextEpisode()` (3950).
- The VC observes `nextEpisode` becoming non-nil to build/set the proposal, reusing the preloaded thumb for `previewImage`.
- On `didAccept`, the VC calls `viewModel.playNextEpisode()`.
- No new persistent state; this is a read + a callback over existing machinery.

### 4. Trigger timing (present at credits marker, with fallbacks)
- **Goal:** present the native card at the Plex **credits marker**. Mechanism: `checkMarkers()` (now wired for Aether via §1) detects the credits marker → host resolves next episode (existing path) → §3 sets the proposal → AVKit surfaces the card.
- **Known unknown (spike risk):** `AVContentProposal` presentation time is governed by AVKit, which historically surfaces the card only in the final ~10s of the item, not at an arbitrary offset. We may not get pixel-control over "show exactly at the credits marker."
  - **If AVKit honors near-marker presentation:** card appears at credits start (the desired Netflix/Apple feel).
  - **If AVKit only allows its default near-end window:** **accept that** — the card still appears, still native, just later. This is an approved fallback.
- **Required callout (not optional):** the implementation MUST emit a runtime log line stating which timing path is live, e.g. `[UpNext] native card presented via {credits-marker | avkit-default} timing`, and the spike results MUST report to the user which one AVKit actually gives. The user wants to know which behavior is active.
- **No credits marker on the episode:** native route → AVKit default near-end presentation; (software route, separate path) → existing 45s-before-end heuristic.

### 5. Reconciliation with the existing `.ended` / `handlePlaybackEnded()` path
- The recent `.ended` wiring routes Aether end-of-stream into `handlePlaybackEnded()`, which mark-watches, scrobbles, fetches next, and (on the software route) shows `EpisodeSummaryOverlay`.
- On the **native route**, when the native card has already handled Up Next (accepted → `playNextEpisode()` already advancing; or rejected → user chose to stop), `handlePlaybackEnded()` must not *also* pop the custom overlay or double-advance. Implementation must guard so the native-card path and the `handlePlaybackEnded()` path do not both drive Up Next for the same episode-end (e.g. a flag set when the native card is presented/accepted, checked in the post-video trigger). The mark-watched/scrobble side effects still run exactly once.
- On the **software route**, nothing changes: no native card, `handlePlaybackEnded()` drives the custom overlay as today.

## Data flow (native route)

```
Aether plays (native route)
        │
 AetherPlayer.timePublisher (0.1s)  ──► [§1] checkMarkers(at:)  (UniversalPlayerViewModel)
        │                                      │
        │                              credits marker detected
        │                                      ▼
        │                         host: fetchNextEpisode() + preloadNextEpisode()
        │                                      │  (sets @Published nextEpisode, caches thumb)
        ▼                                      ▼
AetherPlayerViewController          observes nextEpisode → build AVContentProposal
 (AVPlayerViewControllerDelegate)   → set currentItem.nextContentProposal
        │
   AVKit renders native Up Next card  (timing: credits-marker if honored, else avkit-default — logged)
        │
   ┌────┴───────────────────────────┐
   │ didAccept / auto-accept          │ didReject / no-accept
   ▼                                  ▼
host playNextEpisode()           clear proposal; episode ends →
(Aether loads next; scrobble/CW   handlePlaybackEnded() runs (guarded so it
 intact; ~0.5-1s swap, not         does not double-drive Up Next on native route)
 gapless — deferred)
```

## Error handling & edge cases

- **Next episode fails to resolve** (last episode of series, fetch error): do not set a proposal; no native card. Episode ends → `handlePlaybackEnded()` runs its normal end-of-series behavior.
- **`currentAVPlayer` is nil at trigger time** (route is actually software, or player torn down): no proposal; software-route custom overlay path applies.
- **Route switch mid-playback** (native ↔ software, e.g. reload): the proposal is tied to `currentItem`; on item teardown it is naturally dropped. The `currentAVPlayer` flatMap bind (existing, ~line 169) already tracks player swaps — proposal setup must re-evaluate on player/item change, not assume a stable item.
- **User seeks back out of the credits marker** after the card showed: standard AVKit behavior; if the card was dismissed, `checkMarkers` re-entry should not spam re-presentation (guard with the same "already presented for this episode-end" flag as §5).
- **Auto-skip-credits enabled:** if the user has `autoSkipCredits` on, credits are skipped immediately — interaction with the card is a defined edge. Decision: auto-skip-credits takes precedence (skips to end/next); the card path is mutually exclusive with auto-skipping the credits marker. The implementation must not present the card if credits are being auto-skipped.

## Testing / verification

- **Build gate:** compiles + links into the tvOS app on the concrete arm64 sim destination `platform=tvOS Simulator,name=Apple TV 4K (3rd generation)` (NOT `generic` — libdovi is arm64-only). This is the verification gate; Mac `swift test` is not required.
- **Runtime (user-driven, on device/sim), native route:** play a natively-playable episode with a Plex credits marker on Aether → native Up Next card appears (note via log whether credits-marker or avkit-default timing); accept → next episode loads, finished episode scrobbles and clears from Continue Watching; reject/let-end → no double-advance.
- **Runtime, marker by-product:** intro marker → Skip Intro button appears on Aether (previously absent); auto-skip settings honored.
- **Runtime, software route:** play a DV/FFmpeg episode on Aether → custom `EpisodeSummaryOverlay` still appears as before (no regression, no native card).
- **No-marker episode:** native route shows card in avkit-default window; software route uses 45s heuristic.

## Future to-dos (flagged, not in this spec)

1. **`AVQueuePlayer` migration** of `NativeAVPlayerHost` for true gapless Up Next (native route only). Own spec; high risk; touches Aether's most timing-sensitive code.
2. **Decoy/stub `AVPlayer`** on the software route to render the native card there too. Research spike; FATAL risk = AVKit compositing the decoy surface over the real display-layer video; kill criterion = fall back to custom overlay if so.
