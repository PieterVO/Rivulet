// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  PlaylistRules.swift
//  Rivulet
//
//  What a video playlist allows, shared by both apps. A smart list is the
//  server's rules, so it takes no additions, moves, removals or renames.
//

import Foundation

enum PlaylistRules {
    enum EntryAction: Equatable, Sendable { case playFromHere, move, remove }
    enum PlaylistAction: Equatable, Sendable { case play, shuffle, rename, delete }

    static func entryActions(isSmart: Bool) -> [EntryAction] {
        isSmart ? [.playFromHere] : [.playFromHere, .move, .remove]
    }

    static func playlistActions(isSmart: Bool) -> [PlaylistAction] {
        isSmart ? [.play, .shuffle, .delete] : [.play, .shuffle, .rename, .delete]
    }

    /// The lists Add to Playlist offers: regular ones, by title.
    static func addTargets<List>(_ lists: [List], isSmart: (List) -> Bool, title: (List) -> String) -> [List] {
        lists.filter { !isSmart($0) }
            .sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
    }
}
