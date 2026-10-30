// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StreamInfo.swift
//  Rivulet
//
//  Result of provider.resolveStream(for:sourceID:). The chosen MediaSource
//  with streamURL materialized, plus per-session metadata for progress
//  reporting.
//

import Foundation

/// A provider plan has already decided the subtitle choice, including Off.
/// Player preference code must not replace it with a device-wide default.
enum AuthoritativeSubtitleSelection: Sendable, Equatable {
    case off
    case track(id: String, index: Int)
}

struct StreamInfo: Sendable {
    let source: MediaSource
    let playSessionID: String?
    /// false during HLS transcode where tracks come from the manifest, not from MediaSource fields.
    let trackInfoAvailable: Bool
    /// Ephemeral, plan-scoped transport headers supplied by the owning provider.
    var httpHeaders: [String: String] = [:]
    /// Original delivery location, before any loopback transport, for Home/Away policy.
    var upstreamURL: URL? = nil
    /// The player timeline position supplied by a negotiated playback plan.
    var playerStartTime: TimeInterval? = nil
    /// Source position = player position + this offset for reanchored deliveries.
    var timelineOffset: TimeInterval = 0
    /// False when seeking requires a new provider plan rather than a local player seek.
    var canSeekAnywhere: Bool = true
    /// Uses the existing engine host for sidecar subtitles on negotiated HLS as well as files.
    var prefersAetherPlayback: Bool = false
    /// False when track changes must negotiate the server's desired-track state.
    var canSelectTracksLocally: Bool = true
    /// Native plan facts; nil for older servers and providers without negotiation.
    var negotiatedStatus: MediaNegotiatedStatus? = nil
    /// Non-nil for a provider that owns the initial subtitle decision.
    var authoritativeSubtitleSelection: AuthoritativeSubtitleSelection? = nil
}
