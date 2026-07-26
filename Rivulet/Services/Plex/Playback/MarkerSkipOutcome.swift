// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MarkerSkipOutcome.swift
//  Rivulet
//
//  Pure decision for what pressing a skip pill actually means. Most
//  markers (intro, recap, ad, a mid-stream credits stinger) end inside
//  the media, so skipping them is an ordinary seek. A credits marker
//  that runs to the end of the file is different: there is nothing left
//  to play, so the skip has to finish playback rather than seek.
//

import Foundation

/// What a marker skip should do.
enum MarkerSkipOutcome: Equatable, Sendable {
    /// Seek to `target` and keep playing (intro / recap / ad / a credits
    /// marker that ends mid-stream).
    case seek(target: TimeInterval)

    /// Treat the skip as the end of playback: run the normal end-of-media
    /// funnel (mark watched, Up Next) instead of parking on the last frame.
    case finish
}

enum MarkerSkipPolicy {
    /// How close a credits marker's end has to be to the media end before
    /// the skip counts as "finishing" rather than seeking. Generous by
    /// design: Plex credits markers are frequently a beat short of the
    /// container duration, and the difference is never watchable content.
    static let finishToleranceSeconds: TimeInterval = 1.0

    /// Landing distance from `duration` for an ordinary seek, so we never
    /// seek to literal EOF.
    static let seekEpsilonSeconds: TimeInterval = 0.5

    /// Decide whether skipping this marker finishes playback or seeks.
    ///
    /// A credits marker whose end reaches the media end finishes. Seeking
    /// there instead parks the player on the last frame forever:
    /// `duration - seekEpsilonSeconds` lands exactly inside AetherEngine's
    /// `endOfMediaEpsilonSeconds` window, and the engine deliberately
    /// converts a seek that lands at end-of-media into `.paused` while
    /// withholding the terminal `.ended` it reserves for organic
    /// completion. No `.ended` means the host's end-of-playback handling
    /// never runs, and the `duration - 45` post-video fallback can't
    /// rescue it either — that fallback is gated on there being no credits
    /// marker, and a credits marker is precisely what put the pill
    /// on-screen. Finishing directly is also route-independent: the `hls`
    /// AVPlayer path gets the same behavior without depending on an
    /// end-of-stream notification from an unbuffered tail position.
    ///
    /// - Parameters:
    ///   - isCredits: Whether the marker is a credits/outro marker.
    ///   - markerEnd: The marker's `endTimeSeconds`.
    ///   - duration: Media duration, or 0 when not yet known.
    static func outcome(
        isCredits: Bool,
        markerEnd: TimeInterval,
        duration: TimeInterval
    ) -> MarkerSkipOutcome {
        guard duration > 0 else {
            // Duration unknown (live, or metadata not settled): the only
            // safe move is the plain seek to the marker end.
            return .seek(target: max(0, markerEnd))
        }

        if isCredits && markerEnd >= duration - finishToleranceSeconds {
            return .finish
        }

        return .seek(target: max(0, min(markerEnd, duration - seekEpsilonSeconds)))
    }
}
