// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerDebugLog.swift
//  Rivulet
//
//  Player debug logging: `print` in DEBUG, a no-op in release where the
//  `@autoclosure` keeps the caller's interpolation from being evaluated.
//

import Foundation

@inline(__always)
func playerDebugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
