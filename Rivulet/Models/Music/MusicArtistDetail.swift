//
//  MusicArtistDetail.swift
//  Rivulet
//
//  Superset returned from MusicProvider.artistDetail(for:).
//

import Foundation

struct MusicArtistDetail: Sendable {
    let artist: MusicArtist
    let bio: String?
    let genres: [String]
    let albums: [MusicAlbum]
    let topTracks: [MusicTrack]
    let similarArtists: [MusicArtist]
}
