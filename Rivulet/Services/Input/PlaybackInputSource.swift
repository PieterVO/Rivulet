//
//  PlaybackInputSource.swift
//  Rivulet
//
//  Input source classification for diagnostics/deduplication.
//

import Foundation

enum PlaybackInputSource: String {
    case siriMicroGamepad
    case irPress
    case mpRemoteCommand
    case extendedGamepad
    case keyboard
    case swiftUICommand
    case unknown
}
