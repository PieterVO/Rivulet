//
//  ReplayWindowLogic.swift
//  Rivulet
//
//  Pure logic for the "What did they say?" replay window: jump back 15s
//  with subtitles temporarily on, then auto-revert once playback passes
//  the point where it was invoked (or last extended to, if the user
//  invoked it again while still inside the window).
//

import Foundation

struct ReplayWindowLogic {
    /// Playback time the window reverts at (the point replay was invoked,
    /// or extended to on a repeat invocation).
    let invokedAt: TimeInterval

    /// Subtitle track id active before replay temporarily changed it, or
    /// nil if subtitles were already off. Restored (or, if nil, subtitles
    /// are turned back off) when the window reverts.
    let priorSubtitleTrackId: Int?

    /// True once playback has passed `invokedAt`.
    func shouldRevert(currentTime: TimeInterval) -> Bool {
        currentTime > invokedAt
    }

    /// A repeat invocation while still inside the window extends the
    /// revert point without disturbing `priorSubtitleTrackId`.
    func extended(to invokedAt: TimeInterval) -> ReplayWindowLogic {
        ReplayWindowLogic(invokedAt: invokedAt, priorSubtitleTrackId: priorSubtitleTrackId)
    }
}
