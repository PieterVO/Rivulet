//
//  PlaybackInputAction.swift
//  Rivulet
//
//  Normalized playback actions emitted by remote/controller/keyboard/input paths.
//

import Foundation

enum PlaybackInputAction: Hashable {
    case play
    case pause
    case playPause

    case back
    case showInfo

    case stepSeek(forward: Bool)
    case jumpSeek(forward: Bool)
    case seekRelative(seconds: TimeInterval)
    case seekAbsolute(TimeInterval)

    case scrubNudge(forward: Bool)
    case scrubRelative(seconds: TimeInterval)
    case scrubCommit
    case scrubCancel
}
