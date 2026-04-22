//
//  MusicAlbumDetail.swift
//  Rivulet
//
//  Superset returned from MusicProvider.albumDetail(for:).
//

import Foundation

struct MusicAlbumDetail: Sendable {
    let album: MusicAlbum
    let tracks: [MusicTrack]
    let genres: [String]
    let contributors: [MediaPerson]
}
