//
//  MediaItem.swift
//  Rivulet
//
//  List/browse shape consumed by carousels, hub rows, search results, and
//  any view that renders a media tile. All fields are populated at
//  construction by the provider — nothing is "filled in later." Optional
//  fields mean "this backend doesn't have this data."
//

import Foundation

struct MediaItem: Identifiable, Hashable, Sendable {
    var id: MediaItemRef { ref }
    let ref: MediaItemRef
    let kind: MediaKind

    let title: String
    let sortTitle: String?
    let overview: String?
    let year: Int?
    let runtime: TimeInterval?           // seconds; nil for shows

    // Hierarchy
    let parentRef: MediaItemRef?         // season → show, episode → season
    let grandparentRef: MediaItemRef?    // episode → show
    let episodeNumber: Int?              // episodes only — Plex `index`
    let seasonNumber: Int?               // episodes/seasons only — Plex `parentIndex`
    let childProgress: ChildProgress?    // shows/seasons only — for "12/24 watched"

    let userState: MediaUserState

    // Artwork — own + hierarchy
    let artwork: MediaArtwork
    let parentArtwork: MediaArtwork?     // episode → season art; season → show art
    let grandparentArtwork: MediaArtwork? // episode → show art
}

extension MediaItem {
    /// Returns a copy with `artwork.logo` filled in if it's currently nil.
    /// Used by the prefetch ring to splice a TMDB-resolved logo URL into a
    /// MediaItem whose provider mapper didn't have one at construction time.
    /// A non-nil existing logo is never overwritten.
    func withLogoIfMissing(_ logo: URL?) -> MediaItem {
        guard let logo, artwork.logo == nil else { return self }
        return MediaItem(
            ref: ref,
            kind: kind,
            title: title,
            sortTitle: sortTitle,
            overview: overview,
            year: year,
            runtime: runtime,
            parentRef: parentRef,
            grandparentRef: grandparentRef,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            childProgress: childProgress,
            userState: userState,
            artwork: MediaArtwork(
                poster: artwork.poster,
                backdrop: artwork.backdrop,
                thumbnail: artwork.thumbnail,
                logo: logo
            ),
            parentArtwork: parentArtwork,
            grandparentArtwork: grandparentArtwork
        )
    }
}
