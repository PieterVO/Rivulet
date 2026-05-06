//
//  AudioTrack.swift
//  Rivulet
//
//  Per-audio-stream metadata for the audio picker.
//

import Foundation

struct AudioTrack: Hashable, Sendable, Identifiable {
    let id: String
    let index: Int                 // stream index in the container (AVPlayer track index)
    let codec: String              // "eac3", "dts", "truehd", "aac", "opus"
    let channels: Int?             // 2, 6, 8
    let channelLayout: String?     // "5.1", "7.1", "Atmos" if present
    let language: String?          // "en", "ja"
    let title: String?             // displayable (e.g. "English Commentary")
    let extendedTitle: String?     // long-form Plex `extendedDisplayTitle` etc.
    let bitrate: Int?
    let samplingRate: Int?
    let isDefault: Bool
    let isForced: Bool
    /// Backend-side "this is the user's current pick" flag (Plex `selected: true`,
    /// Jellyfin equivalent). Distinct from `isDefault` — `isDefault` is the
    /// file's authoring default, while `isSelected` reflects a per-user-per-item
    /// override that may have been set in any client.
    let isSelected: Bool
}
