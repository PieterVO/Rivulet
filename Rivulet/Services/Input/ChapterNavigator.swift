// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ChapterNavigator.swift
//  Rivulet
//
//  Pure chapter-snap targeting for the filmstrip scrubber.
//

import Foundation

nonisolated enum ChapterNavigator {
    /// Next/previous chapter start relative to `from`. Backward snaps
    /// within 2s of a boundary skip to the chapter before it.
    static func snapTarget(from time: TimeInterval, chapterStarts: [TimeInterval], forward: Bool) -> TimeInterval? {
        let sorted = chapterStarts.sorted()
        if forward {
            return sorted.first { $0 > time }
        } else {
            return sorted.last { $0 < time - 2 }
        }
    }
}
