//
//  TopShelfItem.swift
//  Rivulet
//
//  Lightweight model for Top Shelf extension data sharing.
//  DUPLICATED verbatim in TopShelfExtension/TopShelfItem.swift — keep identical.
//

import Foundation

struct TopShelfItem: Codable, Sendable {
    let ratingKey: String
    let title: String            // movie name, or EPISODE name for episodes
    let subtitle: String?        // nil for movies; SHOW name for episodes
    let imageURL: String         // tall poster (wide-art fallback)
    let wideImageURL: String     // 16:9 backdrop art
    let logoImageURL: String     // clearLogo URL, "" when none
    let compositeFileName: String?  // "<ratingKey>.jpg" when a composite was written, else nil
    let progress: Double
    let type: String             // "movie" or "episode"
    let lastWatched: Date
    let serverIdentifier: String
}
