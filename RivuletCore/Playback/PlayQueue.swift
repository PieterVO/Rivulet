// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  PlayQueue.swift
//  Rivulet
//
//  The ordered entries a playlist plays through, by position so repeats advance.
//

import Foundation

struct PlayQueue<Entry: Sendable & Equatable>: Sendable, Equatable {
    let entries: [Entry]
    private(set) var index: Int

    init?(entries: [Entry], startingAt index: Int) {
        guard !entries.isEmpty else { return nil }
        self.entries = entries
        self.index = min(max(index, 0), entries.count - 1)
    }

    static func shuffled(_ entries: [Entry]) -> PlayQueue? {
        PlayQueue(entries: entries.shuffled(), startingAt: 0)
    }

    var current: Entry { entries[index] }
    var next: Entry? { index + 1 < entries.count ? entries[index + 1] : nil }

    mutating func advance() { jump(to: index + 1) }

    mutating func jump(to index: Int) {
        self.index = min(max(index, 0), entries.count - 1)
    }

    /// First unwatched entry once anything is watched or started; nil means Play starts at 0.
    static func continuePoint(in entries: [Entry], isPlayed: (Entry) -> Bool, isStarted: (Entry) -> Bool) -> Int? {
        guard entries.contains(where: { isPlayed($0) || isStarted($0) }) else { return nil }
        return entries.firstIndex { !isPlayed($0) }
    }
}
