// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

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
