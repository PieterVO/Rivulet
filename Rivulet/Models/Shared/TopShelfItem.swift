//
//  TopShelfItem.swift
//  Rivulet
//
//  Lightweight model for Top Shelf extension data sharing
//

import Foundation

/// Minimal data structure for Top Shelf items
/// Shared between main app and TV Services Extension via App Groups.
/// DUPLICATED verbatim in TopShelfExtension/TopShelfItem.swift — keep identical.
struct TopShelfItem: Codable, Sendable {
    let ratingKey: String
    let title: String            // movie name, or EPISODE name for episodes
    let subtitle: String?        // nil for movies; SHOW name for episodes
    let imageURL: String         // tall poster (kept as wide-art fallback)
    let wideImageURL: String     // 16:9 backdrop art (primary carousel art)
    let progress: Double         // 0.0-1.0 watch progress
    let type: String             // "movie" or "episode"
    let lastWatched: Date
    let serverIdentifier: String // Server machine ID for deep link
}
