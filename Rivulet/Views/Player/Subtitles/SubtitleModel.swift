// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Combine

// MARK: - SubtitleModel

/// Manages the active-cue set for an Aether-driven subtitle overlay.
///
/// Callers feed this model the current source time and the full cue list
/// from AetherPlayer; the model handles binary-search lookup plus the
/// optional display delay that lets users nudge subtitle timing.
///
/// Operates on `AetherSubtitleCue` (Rivulet's bridge type, carrying text AND
/// bitmap bodies), not Rivulet's text-only `SubtitleCue`, so the
/// overlay can render PGS/DVB bitmap subtitles too.
@MainActor
final class SubtitleModel: ObservableObject {

    // MARK: - Published state

    /// Full sorted cue list. Set via update(cues:).
    @Published var cues: [AetherSubtitleCue] = []

    /// Current source-timeline position in seconds, mirroring AetherPlayer.sourceTime.
    @Published var sourceTime: Double = 0 { didSet { recomputeActiveCues() } }

    /// Subtitle display delay in seconds. Positive values shift subtitles earlier
    /// (reduce effective time), negative values shift later.
    @Published var delaySeconds: Double = 0 { didSet { recomputeActiveCues() } }

    /// Cues on screen right now.
    ///
    /// Published rather than computed at the call site because the clock ticks
    /// several times a second while the visible set changes every few SECONDS.
    /// Recomputing is cheap, but re-rendering is not, so the set is only
    /// reassigned when it actually differs and subscribers can rebuild on every
    /// value they receive.
    @Published private(set) var activeCues: [AetherSubtitleCue] = []

    /// Content keys of `activeCues`, kept alongside it so the change test is a
    /// key comparison rather than a full cue comparison.
    private var activeKeys: [AetherSubtitleCue.ContentKey] = []

    // MARK: - Derived

    /// Maximum cue duration observed in the current cue list, rounded up to
    /// the next whole second, with a minimum of 6 seconds.
    ///
    /// Used by activeCues as the backward-walk window: a binary search lands
    /// on the last cue whose startTime <= t, then the walk goes back until
    /// startTime < t - maxCueDuration. This bounds the scan to a constant
    /// number of cues regardless of list length.
    private(set) var maxCueDuration: Double = 6

    // MARK: - Mutation

    /// Replace the cue list and recompute maxCueDuration.
    ///
    /// Cues must arrive sorted by startTime ascending (AetherEngine guarantees this).
    /// If they aren't, the binary search in activeCues will produce wrong results.
    func update(cues: [AetherSubtitleCue]) {
        self.cues = cues
        // Order matters: the active-set walk is bounded by `maxCueDuration`, so
        // it has to be current before the set is recomputed.
        recomputeMaxDuration()
        recomputeActiveCues()
    }

    /// Recomputes the active set, publishing only when it actually changed.
    private func recomputeActiveCues() {
        let next = computeActiveCues()
        let keys = next.map(\.contentKey)
        guard keys != activeKeys else { return }
        activeKeys = keys
        activeCues = next
    }

    private func recomputeMaxDuration() {
        guard !cues.isEmpty else {
            maxCueDuration = 6
            return
        }
        let maxRaw = cues.reduce(0.0) { acc, cue in
            max(acc, cue.endTime - cue.startTime)
        }
        maxCueDuration = max(maxRaw.rounded(.up), 6)
    }

    // MARK: - Active cue lookup

    /// Cues active at the current effective playback time.
    ///
    /// Effective time = sourceTime - delaySeconds.
    ///
    /// A cue is active when startTime <= t AND endTime >= t (both ends inclusive).
    ///
    /// Algorithm:
    /// 1. Binary search for the rightmost cue with startTime <= t.
    /// 2. Walk leftward as long as startTime > t - maxCueDuration.
    /// 3. Include cues whose endTime >= t.
    /// 4. Drop cues that duplicate an already-collected cue on full content
    ///    identity — `(startTime, endTime, body)`.
    ///
    /// Step 4 exists because AetherEngine 5.0.1 leaks duplicate cues on every
    /// rewind: `SubtitleOverlayDrainer.drainPlan` returns `.resetAndDecode`
    /// on a playhead jump, which resets the decoder but never clears
    /// `subtitleCues`; the re-decoded backscan window is then appended. The
    /// engine's own `insertCueSorted` deliberately keeps *text* cues sharing a
    /// start time (they may be distinct simultaneous speakers), and
    /// `pruneOldSubtitleCues` cannot help because a rewind moves `sourceTime`
    /// backward, leaving the stale copies' `endTime` in the future. So one
    /// line stacks a fresh copy per rewind across it.
    ///
    /// Content identity is the discriminator the engine lacks:
    /// - Two real simultaneous speakers share `startTime` but differ in text
    ///   -> both survive.
    /// - A re-decoded duplicate matches on start AND end AND body
    ///   -> collapses to one.
    ///
    /// This is O(log n + k) where k is the number of active cues (typically
    /// 1-3); the dedupe is a hash-set pass over that same k, not over `cues`.
    private func computeActiveCues() -> [AetherSubtitleCue] {
        let t = sourceTime - delaySeconds
        guard !cues.isEmpty else { return [] }

        // Binary search: find rightmost index where startTime <= t.
        var lo = 0
        var hi = cues.count - 1
        var pivot = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].startTime <= t {
                pivot = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        guard pivot >= 0 else { return [] }

        // Walk left within the maxCueDuration window, dropping cues that
        // duplicate an already-seen cue on full content identity.
        //
        // The walk runs right-to-left, so the copy that survives a duplicate
        // group is the one nearest the END of `cues` — i.e. the most recently
        // appended. Duplicates are identical by construction, so which object
        // survives is immaterial; the subsequent reverse restores startTime
        // order either way.
        let windowStart = t - maxCueDuration
        var result: [AetherSubtitleCue] = []
        var seen: Set<AetherSubtitleCue.ContentKey> = []
        var i = pivot
        while i >= 0 && cues[i].startTime > windowStart {
            let cue = cues[i]
            if cue.startTime <= t && cue.endTime >= t {
                if seen.insert(cue.contentKey).inserted {
                    result.append(cue)
                }
            }
            i -= 1
        }

        // Result was collected right-to-left; reverse to restore startTime order.
        return result.reversed()
    }
}
