// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// A running live session passed between the full-screen player, the guide's corner player (#318)
// and a multiview tile. It rebinds the same player instead of tuning again, so no second tuner grab.
// One surface owns it at a time; the last holder with no use for it calls `stop()`.

import Foundation

@MainActor
final class LiveTVSessionHandoff {
    let channel: UnifiedChannel
    let player: AetherPlayer
    /// The Plex tuner's timeline keepalive, still running. A no-op object for
    /// other sources.
    let keepalive: PlexLiveTimelineKeepalive
    /// Whether AVPlayer is playing the origin's HLS itself, which decides who
    /// renders subtitles once the session lands.
    let isNativeHLSRoute: Bool

    private(set) var isStopped = false

    init(channel: UnifiedChannel, player: AetherPlayer,
         keepalive: PlexLiveTimelineKeepalive, isNativeHLSRoute: Bool) {
        self.channel = channel
        self.player = player
        self.keepalive = keepalive
        self.isNativeHLSRoute = isNativeHLSRoute
    }

    /// End the session: release the tuner and stop the engine.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        keepalive.stop()
        player.stop()
    }
}
