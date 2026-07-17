// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PerfAutoScroll.swift
//  Rivulet
//
//  Perf auto-scroll mode. When on, the home view runs a deterministic
//  scroll sequence on first appear: vertical scroll from top to bottom
//  over ~5 seconds, then horizontal scroll within the first hub. Used by
//  `Scripts/perf_compare.sh` to capture scroll FPS without manual remote
//  input.
//

import Foundation

enum PerfAutoScroll {
    static let storageKey = "perfAutoScrollEnabled"

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }
}
