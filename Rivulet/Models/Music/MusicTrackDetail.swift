//
//  MusicTrackDetail.swift
//  Rivulet
//
//  Superset returned from MusicProvider.trackDetail(for:). Carries lyrics
//  and any other per-track detail beyond what MusicTrack already has.
//

import Foundation

struct MusicTrackDetail: Sendable {
    let track: MusicTrack
    let lyrics: String?
}
