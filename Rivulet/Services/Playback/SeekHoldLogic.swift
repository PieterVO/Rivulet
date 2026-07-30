// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SeekHoldLogic.swift
//  Rivulet
//
//  Pure logic for holding the transport rail at a seek's target until the
//  picture actually gets there.
//
//  `AetherPlayer.seek(to:)` returns when the engine accepts the seek, not
//  when it lands. Since AetherEngine 5.4.1 a native seek is hard-bounded at
//  its recovery budget: on a stalling source it returns with the clock
//  reconciled to the *rendered* frame and completes asynchronously later. So
//  the clock ticks that arrive between accept and landing report the old
//  position, and the rail snaps back to where the user started before
//  jumping to the target. On the software path (all non-HLS live, plus
//  AV1 / VP9 / MPEG-2 / VC-1 / MPEG-4p2 VOD) a spent budget is terminal:
//  nothing re-issues the seek, so nothing hides the snap-back either.
//
//  AetherEngine 6.1.0's `seekEvents` is what makes this decidable — the
//  `isSeeking` level signal's falling edge cannot tell a landing from a
//  give-up from a supersede.
//

import Foundation

/// Tracks which seeks are in flight and what position the rail should show
/// while they are. Hold the clock at the target instead of publishing ticks
/// that predate the landing.
///
/// Seek ids are monotonic per engine instance, so a fresh engine (route
/// change, HLS fallback) needs a fresh value rather than a reset.
struct SeekHoldLogic {

    /// Ids with an unterminated `.began`. Held as a set, not a single id,
    /// because a `.superseded` may be emitted either side of the replacing
    /// seek's `.began`; while any id is in flight the hold stands.
    private var inFlight: Set<UInt64> = []

    /// Position to show while holding: the newest in-flight target.
    private(set) var heldTime: TimeInterval?

    /// True while at least one seek is unsettled, i.e. clock ticks describe a
    /// position the picture has already left.
    var isHolding: Bool { !inFlight.isEmpty }

    /// Fold one event in. Returns the time the rail should jump to now, or
    /// nil to leave the displayed position alone.
    ///
    /// A `.stalled` seek releases the hold even though a late `.landed` can
    /// still follow under the same id: the engine holds its clock AT the
    /// target for exactly that case, so releasing shows the target rather
    /// than freezing the rail on a landing that may never come.
    mutating func apply(_ event: SeekHoldEvent) -> TimeInterval? {
        switch event.outcome {
        case .began:
            inFlight.insert(event.id)
            heldTime = event.target
            return event.target
        case .landed(let renderedTime):
            inFlight.remove(event.id)
            guard !isHolding else { return nil }
            heldTime = nil
            // Keyframe granularity and a playing item's overshoot put the
            // rendered position a few seconds off target; it is the truth.
            return renderedTime
        case .settledElsewhere:
            inFlight.remove(event.id)
            guard !isHolding else { return nil }
            heldTime = nil
            return nil
        }
    }
}

/// One seek lifecycle event in host terms. `AetherPlayer` maps AetherEngine's
/// `SeekEvent` onto this so the view model needs no `import AetherEngine` —
/// the wrapper stays the only file coupled to the engine's API.
struct SeekHoldEvent: Equatable {

    /// The subset of `SeekEvent.Outcome` the hold distinguishes. `.rejected`
    /// never has a `.began`, so it has nothing to release and is not modelled.
    enum Outcome: Equatable {
        case began
        case landed(renderedTime: TimeInterval)
        /// `.stalled` or `.superseded`: the window closed without a landing
        /// to report.
        case settledElsewhere
    }

    /// Identifies one seek across its events; monotonic per engine instance.
    let id: UInt64
    let outcome: Outcome
    /// Destination on the `currentTime` axis.
    let target: TimeInterval
}
