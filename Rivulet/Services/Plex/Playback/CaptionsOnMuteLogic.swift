// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CaptionsOnMuteLogic.swift
//  Rivulet
//
//  Subtitles shown while tvOS reports Show When Muted, then put back. Never
//  touches the saved subtitle preference.
//

import Foundation

struct CaptionsOnMuteLogic {
    /// The track turned on for mute and the one it replaced (nil = off).
    private(set) var shown: (track: Int, prior: Int?)?
    /// True once this mute has been handled: subtitles turned on, or the user picked.
    private var settled = false

    /// The track to switch to, or nil to leave subtitles alone. A forced-only
    /// track counts as off.
    mutating func activate(current: MediaTrack?, tracks: [MediaTrack],
                           preferredLanguage: String?, audioLanguage: String?) -> Int? {
        guard !settled else { return nil }
        if let current, !current.isForced { return nil }
        guard let pick = Self.track(in: tracks, preferredLanguage: preferredLanguage,
                                    audioLanguage: audioLanguage) else { return nil }
        settled = true
        shown = (pick.id, current?.id)
        return pick.id
    }

    /// `.some(id)` restores that track (nil = off); `nil` leaves subtitles alone
    /// because the user changed them meanwhile.
    mutating func deactivate(currentTrackId: Int?) -> Int?? {
        defer { self = Self() }
        guard let shown, shown.track == currentTrackId else { return nil }
        return .some(shown.prior)
    }

    /// The user picked a track: theirs stands for the rest of this mute.
    mutating func userPicked() {
        shown = nil
        settled = true
    }

    /// The language a saved subtitle pick names, if any.
    static func language(of intent: SubtitleIntent?) -> String? {
        if case let .track(language, _, _, _) = intent { return language }
        return nil
    }

    /// Preferred subtitle language, else the audio language, else the first
    /// full track; text before image within each tier.
    static func track(in tracks: [MediaTrack], preferredLanguage: String?, audioLanguage: String?) -> MediaTrack? {
        let full = tracks.filter { !$0.isForced }
        let ordered = full.filter { ContentFilterSources.isTextSubtitle(codec: $0.codec) }
            + full.filter { !ContentFilterSources.isTextSubtitle(codec: $0.codec) }
        for language in [preferredLanguage, audioLanguage] {
            let key = TrackLanguage.normalize(language)
            guard !key.isEmpty else { continue }
            if let match = ordered.first(where: {
                TrackLanguage.normalize($0.languageCode) == key || TrackLanguage.normalize($0.language) == key
            }) { return match }
        }
        return ordered.first
    }
}
