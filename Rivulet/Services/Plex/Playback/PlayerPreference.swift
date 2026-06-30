//
//  PlayerPreference.swift
//  Rivulet
//
//  User-selectable video player engine for VOD. Three engines, picked by
//  a cycling picker in Settings (Rivulet Player is the default):
//
//  - .rivulet (default): RivuletPlayer (custom FFmpeg + AVSampleBuffer).
//    Fast local playback, broad container support, no server transcode for
//    nearly every file Apple TV can decode. Also powers Live TV.
//  - .aether: AetherEngine via AVPlayerViewController. Native
//    HDR10+, HLG, EAC3+JOC Atmos, DV P5/P8.1, lossless TrueHD/DTS. Sources
//    it can't reach natively (DV P7, AV1) play as HDR10 base / fall back.
//  - .apple: AVPlayer paths (avPlayerDirect / localRemux / HLS).
//

import Foundation

enum PlayerPreference: String, CaseIterable, Sendable, CustomStringConvertible {
    case aether
    case apple
    case rivulet

    /// Used by SettingsPickerRow to display the current selection.
    var description: String { displayName }

    /// UserDefaults key for the preference.
    static let userDefaultsKey = "playerPreference"

    /// The current preference. Missing value means a new install, which
    /// defaults to Rivulet Player.
    static var current: PlayerPreference {
        if let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
           let pref = PlayerPreference(rawValue: raw) {
            return pref
        }
        return .rivulet
    }

    static func set(_ pref: PlayerPreference) {
        UserDefaults.standard.set(pref.rawValue, forKey: userDefaultsKey)
    }

    /// Display label for the Settings picker.
    var displayName: String {
        switch self {
        case .aether:  return "Aether"
        case .apple:   return "Apple AVPlayer"
        case .rivulet: return "Rivulet Player"
        }
    }
}
