//
//  LegacyTrackPreferenceShim.swift
//  Rivulet
//
//  ⚠️ TEMPORARY — DELETE THIS ENTIRE FILE IN PART 3 (Settings removal).
//
//  Track memory now lives in TrackIntent.swift (SubtitleIntent / AudioIntent /
//  TrackIntentStore). The only remaining callers of the old
//  SubtitlePreference / AudioPreference API are the two Settings → Playback
//  rows (`audioLanguage`, `subtitles`) in
//  Views/Settings/UIKit/SettingsPageModels.swift, which Part 3 deletes.
//
//  This file exists solely so the tree compiles between Part 2 and Part 3.
//  It is a thin read/write adapter onto TrackIntentStore — no independent
//  storage, no resolution logic. When Part 3 removes those Settings rows,
//  delete this file; nothing else references it.
//

import Foundation

@available(*, deprecated, message: "Use SubtitleIntent / TrackIntentStore. Removed in Part 3.")
struct SubtitlePreference: Equatable {
    var enabled: Bool
    var languageCode: String?

    static let off = SubtitlePreference(enabled: false, languageCode: nil)
}

@available(*, deprecated, message: "Use TrackIntentStore.subtitleIntent. Removed in Part 3.")
enum SubtitlePreferenceManager {
    static var current: SubtitlePreference {
        get {
            switch TrackIntentStore.subtitleIntent {
            case .none:
                return .off
            case .off:
                return .off
            case let .track(language, _, _, _):
                return SubtitlePreference(enabled: true, languageCode: language)
            }
        }
        set {
            guard newValue.enabled, let language = newValue.languageCode, !language.isEmpty else {
                TrackIntentStore.subtitleIntent = .off
                return
            }
            // Settings can only express a language. Preserve the forced /
            // hearing-impaired / codec bits of an existing same-language intent
            // rather than silently flattening them.
            if case let .track(existingLanguage, forced, hi, codec) = TrackIntentStore.subtitleIntent,
               TrackLanguage.matches(existingLanguage, language) {
                TrackIntentStore.subtitleIntent = .track(
                    language: language, forced: forced, hearingImpaired: hi, codec: codec
                )
            } else {
                TrackIntentStore.subtitleIntent = .track(
                    language: language, forced: false, hearingImpaired: false, codec: nil
                )
            }
        }
    }
}

@available(*, deprecated, message: "Use AudioIntent / TrackIntentStore. Removed in Part 3.")
struct AudioPreference: Equatable {
    var languageCode: String?

    init(languageCode: String?) {
        self.languageCode = languageCode
    }
}

@available(*, deprecated, message: "Use TrackIntentStore.audioIntent. Removed in Part 3.")
enum AudioPreferenceManager {
    static var current: AudioPreference {
        get { AudioPreference(languageCode: TrackIntentStore.effectiveAudioIntent.language) }
        set {
            guard let language = newValue.languageCode, !language.isEmpty else {
                TrackIntentStore.audioIntent = nil
                return
            }
            // Settings expresses a language only — drop any codec/channel
            // specificity from a previous in-player pick.
            TrackIntentStore.audioIntent = AudioIntent(language: language)
        }
    }
}
