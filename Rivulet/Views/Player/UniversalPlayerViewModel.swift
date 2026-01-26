//
//  UniversalPlayerViewModel.swift
//  Rivulet
//
//  ViewModel managing playback state using MPV player
//

import SwiftUI
import Combine
import UIKit
import Sentry

// MARK: - Subtitle Preference

/// Stores user's subtitle preference for auto-selection
struct SubtitlePreference: Codable, Equatable {
    /// Whether subtitles are enabled
    var enabled: Bool
    /// Preferred language code (e.g., "en", "es")
    var languageCode: String?
    /// Preferred codec (e.g., "srt", "ass", "pgs")
    var codec: String?
    /// Whether to prefer hearing impaired tracks
    var preferHearingImpaired: Bool

    static let off = SubtitlePreference(enabled: false, languageCode: nil, codec: nil, preferHearingImpaired: false)

    init(enabled: Bool, languageCode: String?, codec: String?, preferHearingImpaired: Bool) {
        self.enabled = enabled
        self.languageCode = languageCode
        self.codec = codec
        self.preferHearingImpaired = preferHearingImpaired
    }

    /// Create preference from a selected track
    init(from track: MediaTrack) {
        self.enabled = true
        self.languageCode = track.languageCode
        self.codec = track.codec
        self.preferHearingImpaired = track.isHearingImpaired
    }
}

/// Manages subtitle preference persistence
enum SubtitlePreferenceManager {
    // Individual keys for each preference field (more robust than JSON)
    private static let enabledKey = "subtitlePreferenceEnabled"
    private static let languageKey = "subtitlePreferenceLanguage"
    private static let codecKey = "subtitlePreferenceCodec"
    private static let hearingImpairedKey = "subtitlePreferenceHearingImpaired"

    // Migration from old JSON format
    private static let migrationKey = "subtitlePreferenceMigrated"

    static var current: SubtitlePreference {
        get {
            // Migrate from old JSON format if needed
            if !UserDefaults.standard.bool(forKey: migrationKey) {
                UserDefaults.standard.set(true, forKey: migrationKey)
                if let data = UserDefaults.standard.data(forKey: "subtitlePreference"),
                   let oldPref = try? JSONDecoder().decode(SubtitlePreference.self, from: data) {
                    // Migrate old values to new format
                    UserDefaults.standard.set(oldPref.enabled, forKey: enabledKey)
                    UserDefaults.standard.set(oldPref.languageCode, forKey: languageKey)
                    UserDefaults.standard.set(oldPref.codec, forKey: codecKey)
                    UserDefaults.standard.set(oldPref.preferHearingImpaired, forKey: hearingImpairedKey)
                    UserDefaults.standard.removeObject(forKey: "subtitlePreference")
                }
            }

            // Read from individual keys
            let enabled = UserDefaults.standard.bool(forKey: enabledKey)
            let languageCode = UserDefaults.standard.string(forKey: languageKey)
            let codec = UserDefaults.standard.string(forKey: codecKey)
            let preferHearingImpaired = UserDefaults.standard.bool(forKey: hearingImpairedKey)

            return SubtitlePreference(
                enabled: enabled,
                languageCode: languageCode,
                codec: codec,
                preferHearingImpaired: preferHearingImpaired
            )
        }
        set {
            UserDefaults.standard.set(newValue.enabled, forKey: enabledKey)
            UserDefaults.standard.set(newValue.languageCode, forKey: languageKey)
            UserDefaults.standard.set(newValue.codec, forKey: codecKey)
            UserDefaults.standard.set(newValue.preferHearingImpaired, forKey: hearingImpairedKey)
        }
    }

    /// Find best matching subtitle track based on preference
    static func findBestMatch(in tracks: [MediaTrack], preference: SubtitlePreference) -> MediaTrack? {
        guard preference.enabled, let preferredLang = preference.languageCode else {
            return nil
        }

        // Filter tracks by language
        let langMatches = tracks.filter { $0.languageCode == preferredLang }
        guard !langMatches.isEmpty else {
            // No tracks match preferred language - keep subtitles off
            return nil
        }

        // Try to find exact codec match
        if let preferredCodec = preference.codec {
            if let exactMatch = langMatches.first(where: {
                $0.codec == preferredCodec && $0.isHearingImpaired == preference.preferHearingImpaired
            }) {
                return exactMatch
            }
            // Try codec match without hearing impaired preference
            if let codecMatch = langMatches.first(where: { $0.codec == preferredCodec }) {
                return codecMatch
            }
        }

        // Fall back to first track of preferred language with matching HI preference
        if let hiMatch = langMatches.first(where: { $0.isHearingImpaired == preference.preferHearingImpaired }) {
            return hiMatch
        }

        // Fall back to first track of preferred language
        return langMatches.first
    }
}

// MARK: - Audio Preference

/// Stores user's audio preference for auto-selection
struct AudioPreference: Codable, Equatable {
    /// Preferred language code (e.g., "en", "es"). Nil means default to English.
    var languageCode: String?

    static let defaultEnglish = AudioPreference(languageCode: "eng")

    /// Create preference from a selected track
    init(from track: MediaTrack) {
        self.languageCode = track.languageCode
    }

    init(languageCode: String?) {
        self.languageCode = languageCode
    }
}

/// Manages audio preference persistence
enum AudioPreferenceManager {
    private static let languageKey = "audioPreferenceLanguage"

    // Migration: try to read old JSON format once
    private static let migrationKey = "audioPreferenceMigrated"

    static var current: AudioPreference {
        get {
            // Migrate from old JSON format if needed
            if !UserDefaults.standard.bool(forKey: migrationKey) {
                UserDefaults.standard.set(true, forKey: migrationKey)
                if let data = UserDefaults.standard.data(forKey: "audioPreference"),
                   let oldPref = try? JSONDecoder().decode(AudioPreference.self, from: data) {
                    // Migrate old value to new format
                    UserDefaults.standard.set(oldPref.languageCode, forKey: languageKey)
                    UserDefaults.standard.removeObject(forKey: "audioPreference")
                }
            }

            // Read from simple string storage
            let languageCode = UserDefaults.standard.string(forKey: languageKey)
            return AudioPreference(languageCode: languageCode ?? "eng")
        }
        set {
            UserDefaults.standard.set(newValue.languageCode, forKey: languageKey)
        }
    }

    /// Find best matching audio track based on preference
    /// Returns the highest quality track in the preferred language, falling back to English
    static func findBestMatch(in tracks: [MediaTrack], preference: AudioPreference) -> MediaTrack? {
        guard !tracks.isEmpty else { return nil }

        // Helper to find best track by quality (most channels = better)
        func bestTrack(in candidates: [MediaTrack]) -> MediaTrack? {
            candidates.max { ($0.channels ?? 0) < ($1.channels ?? 0) }
        }

        // Try preferred language first
        if let preferredLang = preference.languageCode {
            let langMatches = tracks.filter {
                $0.languageCode?.lowercased() == preferredLang.lowercased()
            }
            if let best = bestTrack(in: langMatches) {
                return best
            }
        }

        // Fall back to English tracks
        let englishMatches = tracks.filter {
            let code = $0.languageCode?.lowercased()
            return code == "eng" || code == "en" || code == "english"
        }
        if let best = bestTrack(in: englishMatches) {
            return best
        }

        // No English either - return the first track (usually default)
        return tracks.first(where: { $0.isDefault }) ?? tracks.first
    }
}

// MARK: - Post-Video State

/// State machine for post-video summary experience
enum PostVideoState: Equatable {
    case hidden
    case loading
    case showingEpisodeSummary
    case showingMovieSummary
}

/// Video frame state for shrink animation
enum VideoFrameState: Equatable {
    case fullscreen
    case shrunk

    var scale: CGFloat {
        switch self {
        case .fullscreen: return 1.0
        case .shrunk: return 0.25  // 25% size - roughly 480x270 on 1920x1080
        }
    }

    var offset: CGSize {
        switch self {
        case .fullscreen: return .zero
        case .shrunk: return CGSize(width: 60, height: 60)  // Padding from top-left corner
        }
    }
}

/// Seek indicator shown briefly when user taps left/right to skip
enum SeekIndicator: Equatable {
    case forward(Int)   // seconds skipped forward
    case backward(Int)  // seconds skipped backward

    var systemImage: String {
        switch self {
        case .forward: return "goforward.10"
        case .backward: return "gobackward.10"
        }
    }

    var seconds: Int {
        switch self {
        case .forward(let s), .backward(let s): return s
        }
    }
}

/// Player engine type for video playback
enum PlayerType: Equatable {
    case mpv
    case avplayer
}

@MainActor
final class UniversalPlayerViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var playbackState: UniversalPlaybackState = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var errorMessage: String?

    @Published var showControls = true
    @Published var showInfoPanel = false
    @Published var isScrubbing = false
    @Published var showPausedPoster = false
    @Published var shouldDismiss = false  // Used to request player dismissal on tvOS
    @Published var compatibilityNotice: String?

    // MARK: - Seek Indicator State
    /// Shows a brief indicator when user taps left/right to skip 10 seconds
    @Published var seekIndicator: SeekIndicator?

    // MARK: - Skip Marker State
    @Published private(set) var activeMarker: PlexMarker?
    @Published private(set) var showSkipButton = false
    private var hasSkippedIntro = false
    private var hasSkippedCredits = false
    private var skippedCommercialIds: Set<Int> = []  // Track skipped commercials by ID
    private var hasTriggeredPostVideo = false
    @Published var scrubTime: TimeInterval = 0

    // MARK: - Post-Video State
    @Published var postVideoState: PostVideoState = .hidden
    @Published var videoFrameState: VideoFrameState = .fullscreen
    @Published private(set) var nextEpisode: PlexMetadata?
    @Published private(set) var recommendations: [PlexMetadata] = []
    @Published var countdownSeconds: Int = 0
    @Published var isCountdownPaused: Bool = false
    private var countdownTimer: Timer?
    @Published var scrubThumbnail: UIImage?
    @Published private(set) var scrubSpeed: Int = 0  // -1, 0, or 1 (direction only)
    private var scrubStartTime: Date?  // When scrubbing started (for YouTube-style acceleration)
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var currentAudioTrackId: Int?
    @Published private(set) var currentSubtitleTrackId: Int?
    private var compatibilityNoticeTimer: Timer?

    // MARK: - Playback Settings Panel State (Column-based layout)

    /// Which column is focused: 0 = Subtitles, 1 = Audio (Media Info is not focusable)
    @Published var focusedColumn: Int = 0

    /// Which row within the focused column
    @Published var focusedRowIndex: Int = 0

    /// Number of rows in a given column
    func rowCount(forColumn column: Int) -> Int {
        switch column {
        case 0: return 1 + subtitleTracks.count  // "Off" + subtitle tracks
        case 1: return max(1, audioTracks.count)  // Audio tracks (at least 1)
        default: return 0
        }
    }

    /// Check if a specific setting is focused
    func isSettingFocused(column: Int, index: Int) -> Bool {
        return focusedColumn == column && focusedRowIndex == index
    }

    /// Navigate within settings panel
    func navigateSettings(direction: MoveCommandDirection) {
        switch direction {
        case .up:
            if focusedRowIndex > 0 {
                focusedRowIndex -= 1
            }
        case .down:
            let maxIndex = rowCount(forColumn: focusedColumn) - 1
            if focusedRowIndex < maxIndex {
                focusedRowIndex += 1
            }
        case .left:
            if focusedColumn > 0 {
                focusedColumn -= 1
                // Clamp row index to new column's range
                focusedRowIndex = min(focusedRowIndex, rowCount(forColumn: focusedColumn) - 1)
            }
        case .right:
            if focusedColumn < 1 {  // Only 2 focusable columns (0 and 1)
                focusedColumn += 1
                // Clamp row index to new column's range
                focusedRowIndex = min(focusedRowIndex, rowCount(forColumn: focusedColumn) - 1)
            }
        @unknown default:
            break
        }
    }

    /// Select the currently focused setting
    func selectFocusedSetting() {
        switch focusedColumn {
        case 0:  // Subtitles
            if focusedRowIndex == 0 {
                selectSubtitleTrack(id: nil)
                print("🎬 [SETTINGS] Selected subtitles: Off")
            } else {
                let trackIndex = focusedRowIndex - 1
                if trackIndex < subtitleTracks.count {
                    selectSubtitleTrack(id: subtitleTracks[trackIndex].id)
                    print("🎬 [SETTINGS] Selected subtitle: \(subtitleTracks[trackIndex].name)")
                }
            }
        case 1:  // Audio
            if focusedRowIndex < audioTracks.count {
                selectAudioTrack(id: audioTracks[focusedRowIndex].id)
                print("🎬 [SETTINGS] Selected audio: \(audioTracks[focusedRowIndex].name)")
            }
        default:
            break
        }
    }

    // MARK: - Player Instance

    /// The player engine being used for this playback session
    /// Published so the view can react to fallback from AVPlayer to MPV
    @Published private(set) var playerType: PlayerType = .mpv

    /// MPV player (used for most content)
    /// Published so the view can react to fallback from AVPlayer to MPV
    @Published private(set) var mpvPlayerWrapper: MPVPlayerWrapper?

    /// AVPlayer (used for Dolby Vision when enabled)
    @Published private(set) var avPlayerWrapper: AVPlayerWrapper?

    // MARK: - Metadata

    private(set) var metadata: PlexMetadata
    var title: String { metadata.title ?? "Unknown" }
    var subtitle: String? {
        if metadata.type == "episode" {
            let show = metadata.grandparentTitle ?? ""
            let season = metadata.parentIndex.map { "S\($0)" } ?? ""
            let episode = metadata.index.map { "E\($0)" } ?? ""
            return "\(show) \(season)\(episode)"
        }
        return metadata.year.map { String($0) }
    }

    // MARK: - Private State

    private var cancellables = Set<AnyCancellable>()
    private var controlsTimer: Timer?
    private let controlsHideDelay: TimeInterval = 5
    private var scrubTimer: Timer?
    private var appBecameActiveObserver: Any?
    private var appBackgroundObserver: Any?
    private var pausedDueToAppInactive: Bool = false
    private let scrubUpdateInterval: TimeInterval = 0.1  // 100ms updates for smooth scrubbing
    private var seekIndicatorTimer: Timer?
    private var pausedPosterTimer: Timer?
    private let pausedPosterDelay: TimeInterval = 5.0

    // MARK: - Playback Context

    let serverURL: String
    let authToken: String
    private(set) var startOffset: TimeInterval?

    // MARK: - Loading Screen Images (passed from detail view for instant display)

    let loadingArtImage: UIImage?
    let loadingThumbImage: UIImage?

    // MARK: - Stream URL (computed once)

    @Published private(set) var streamURL: URL?
    private(set) var streamHeaders: [String: String] = [:]
    private let allowAudioDirectStream: Bool

    // MARK: - Preloaded Next Episode Data

    private var preloadedNextStreamURL: URL?
    private var preloadedNextStreamHeaders: [String: String] = [:]
    private var preloadedNextMetadata: PlexMetadata?

    // MARK: - Initialization

    init(
        metadata: PlexMetadata,
        serverURL: String,
        authToken: String,
        startOffset: TimeInterval? = nil,
        loadingArtImage: UIImage? = nil,
        loadingThumbImage: UIImage? = nil
    ) {
        self.metadata = metadata
        self.serverURL = serverURL
        self.authToken = authToken
        self.startOffset = startOffset
        self.loadingArtImage = loadingArtImage
        self.loadingThumbImage = loadingThumbImage
        self.allowAudioDirectStream = UniversalPlayerViewModel.isAudioDirectStreamCapable(metadata)

        // Determine which player to use based on content and settings
        let useAVPlayerForDV = UserDefaults.standard.bool(forKey: "useAVPlayerForDolbyVision")
        let useAVPlayerForAll = UserDefaults.standard.bool(forKey: "useAVPlayerForAllVideos")
        let hasDolbyVision = metadata.hasDolbyVision

        // Get container format for logging
        let container = metadata.Media?.first?.Part?.first?.container?.lowercased() ?? ""

        // Identify DV stream (could be second video track in dual-layer profile 7)
        let videoStreams = metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isVideo } ?? []
        let dvStream = videoStreams.first { ($0.DOVIProfile != nil) || ($0.DOVIPresent == true) }

        // Check DV profile compatibility - only Profile 5 and 8 work with Apple TV's native player
        // Profile 8 requires BL Compat ID 1 (HDR10-compatible base layer) or 4 (P8.4 camera)
        // Profile 7 (dual-layer) is NOT compatible with AVPlayer
        let dvProfile = dvStream?.DOVIProfile
        let doviBLCompatID = dvStream?.DOVIBLCompatID
        let isCompatibleDVProfile: Bool = {
            // If Plex metadata doesn't report profile yet, assume compatible and let fallbacks handle errors.
            guard let dvProfile else { return true }

            if dvProfile == 5 { return true }
            if dvProfile == 8 {
                // Allow HDR10-compatible base (1) and Apple camera P8.4 (4); unknown BLCompat also allowed
                return doviBLCompatID == nil || doviBLCompatID == 1 || doviBLCompatID == 4
            }
            return false
        }()

        // For DV content via AVPlayer:
        // - MP4/MOV containers: Direct play works
        // - MKV containers: Plex HLS remux handles container conversion
        let canUseAVPlayerForDV = hasDolbyVision && isCompatibleDVProfile

        print("[Player Selection] useAVPlayerForAll=\(useAVPlayerForAll), useAVPlayerForDV=\(useAVPlayerForDV), hasDolbyVision=\(hasDolbyVision), dvProfile=\(dvProfile ?? -1), blCompatID=\(doviBLCompatID ?? -1), isCompatible=\(isCompatibleDVProfile), container=\(container)")

        // Use AVPlayer if:
        // 1. "Use AVPlayer for All Videos" is enabled, OR
        // 2. "Use AVPlayer for DV" is enabled AND content has compatible DV profile AND direct-playable container
        if useAVPlayerForAll || (useAVPlayerForDV && canUseAVPlayerForDV) {
            if useAVPlayerForAll {
                print("[Player Selection] → Using AVPlayer (all videos mode)")
            } else {
                print("[Player Selection] → Using AVPlayer for Dolby Vision Profile \(dvProfile ?? 0)")
            }
            self.playerType = .avplayer
            self.avPlayerWrapper = AVPlayerWrapper()
            self.mpvPlayerWrapper = nil
        } else {
            print("[Player Selection] → Using MPV")
            self.playerType = .mpv
            self.mpvPlayerWrapper = MPVPlayerWrapper()
            self.avPlayerWrapper = nil

            // Show notice explaining why we're using MPV instead of AVPlayer for DV
            if useAVPlayerForDV && hasDolbyVision && !isCompatibleDVProfile {
                showCompatibilityNotice("DV Profile \(dvProfile ?? 0) not supported — playing HDR10")
            }
        }

        setupPlayer()

        // Prepare stream URL asynchronously (may need to fetch full metadata for audio)
        Task { @MainActor in
            await prepareStreamURL()
        }

        addPlaybackSelectionBreadcrumb(reason: "init")
    }

    private func setupPlayer() {
        bindPlayerState()
        observeAppLifecycle()
    }

    /// Observe app lifecycle to pause playback when app goes to background
    /// Only pauses on actual background entry (not Control Center overlay)
    private func observeAppLifecycle() {
        // Only pause when actually entering background (home button, sleep, etc.)
        // This does NOT fire for Control Center overlay on tvOS
        appBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            print("🎬 [Lifecycle] App entered background - pausing")
            if self.playbackState == .playing {
                self.pausedDueToAppInactive = true
                Task { @MainActor in
                    self.pause()
                }
            }
        }

        // When returning from background, keep paused (user must manually resume)
        appBecameActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.pausedDueToAppInactive {
                print("🎬 [Lifecycle] Returning from background - keeping paused")
                self.pausedDueToAppInactive = false
            }
        }
    }

    private func prepareStreamURL() async {
        let networkManager = PlexNetworkManager.shared

        guard let ratingKey = metadata.ratingKey else { return }

        // Check if this is audio content
        let isAudio = metadata.type == "track" || metadata.type == "album" || metadata.type == "artist"

        // AVPlayer: Check if source is compatible for true direct play (no server processing)
        // Otherwise fall back to HLS remux which handles container conversion and codec tag fixes
        if playerType == .avplayer {
            let container = metadata.Media?.first?.container?.lowercased() ?? ""

            // Check if the source file is already AVPlayer-compatible
            if isAVPlayerDirectPlayCompatible(metadata), let partKey = metadata.Media?.first?.Part?.first?.key {
                // True direct play - no server processing needed
                print("[AVPlayer] Direct play compatible (\(container.uppercased())) - using raw file stream")
                if let url = networkManager.buildVLCDirectPlayURL(
                    serverURL: serverURL,
                    authToken: authToken,
                    partKey: partKey
                ) {
                    streamURL = url
                    streamHeaders = [
                        "X-Plex-Token": authToken,
                        "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
                        "X-Plex-Platform": PlexAPI.platform,
                        "X-Plex-Device": PlexAPI.deviceName,
                        "X-Plex-Product": PlexAPI.productName
                    ]
                    print("[AVPlayer] Direct play URL: \(url.absoluteString)")
                    return
                }
            }

            // Not direct-play compatible - use HLS remux
            // This handles: MKV containers, incompatible codecs, DTS/TrueHD audio, bad codec tags (dvhe/hev1)
            // Note: For MKV + DV, player selection should have routed to MPV (more reliable)
            // This path is hit when "Use AVPlayer for All" is enabled
            print("[AVPlayer] Not direct-play compatible (\(container.uppercased())) - using HLS remux")

            // For DV content via HLS remux, Plex handles container conversion
            let useDV = metadata.hasDolbyVision
            isUsingDolbyVisionHLS = useDV

            if metadata.hasDolbyVision {
                print("[AVPlayer] Using DV HLS (container: \(container.uppercased()))")
            }

            if let result = networkManager.buildHLSDirectPlayURL(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey,
                offsetMs: Int((startOffset ?? 0) * 1000),
                hasHDR: metadata.hasHDR,
                useDolbyVision: useDV,
                forceVideoTranscode: false,  // avoid transcoding; rely on DV remux + codec tag fixes
                allowAudioDirectStream: allowAudioDirectStream
            ) {
                streamURL = result.url
                streamHeaders = result.headers
                print("[AVPlayer] HLS URL: \(result.url.absoluteString)")
            }

            return
        }

        // MPV: Use true direct play - stream raw file without any transcoding
        // MPV can handle MKV, HEVC, H264, DTS, TrueHD, ASS/SSA subs natively with HDR passthrough

        // Try to get partKey from existing metadata
        var partKey = metadata.Media?.first?.Part?.first?.key

        // For audio content, if partKey is missing, fetch full metadata to get it
        if isAudio && partKey == nil {
            do {
                let fullMetadata = try await networkManager.getMetadata(
                    serverURL: serverURL,
                    authToken: authToken,
                    ratingKey: ratingKey
                )
                partKey = fullMetadata.Media?.first?.Part?.first?.key
            } catch {
                // Continue with fallback
            }
        }

        if let partKey = partKey {
            streamURL = networkManager.buildVLCDirectPlayURL(
                serverURL: serverURL,
                authToken: authToken,
                partKey: partKey
            )
        } else {
            // Fallback to direct stream if no part key available
            streamURL = networkManager.buildDirectStreamURL(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey,
                offsetMs: Int((startOffset ?? 0) * 1000),
                isAudio: isAudio
            )
        }

        streamHeaders = [
            "X-Plex-Token": authToken,
            "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
            "X-Plex-Platform": PlexAPI.platform,
            "X-Plex-Device": PlexAPI.deviceName,
            "X-Plex-Product": PlexAPI.productName
        ]
    }

    /// Check if the source file is compatible with AVPlayer for true direct play (no server processing).
    /// Returns true if the file can be played directly without remuxing or transcoding.
    private func isAVPlayerDirectPlayCompatible(_ metadata: PlexMetadata) -> Bool {
        guard let media = metadata.Media?.first,
              let part = media.Part?.first else { return false }

        // AVPlayer-compatible containers: mp4, mov, m4v
        let container = media.container?.lowercased() ?? ""
        guard ["mp4", "mov", "m4v"].contains(container) else { return false }

        // Check video codec - must be h264 or hevc
        let videoStream = part.Stream?.first { $0.isVideo }
        let videoCodec = videoStream?.codec?.lowercased() ?? ""
        guard ["h264", "hevc"].contains(videoCodec) else { return false }

        // Check for incompatible codec tags that need remuxing
        // dvhe and hev1 need to be converted to dvh1 and hvc1 for tvOS compatibility
        let codecTag = videoStream?.codecID?.lowercased() ?? ""
        if codecTag == "dvhe" || codecTag == "hev1" { return false }

        // Check audio codec - must be aac, ac3, or eac3
        // DTS and TrueHD require transcoding (handled by HLS remux path)
        let audioStream = part.Stream?.first { $0.isAudio }
        let audioCodec = audioStream?.codec?.lowercased() ?? ""
        guard ["aac", "ac3", "eac3"].contains(audioCodec) else { return false }

        return true
    }

    /// Determines whether audio can be safely direct-streamed to AVPlayer.
    /// DTS/TrueHD should be transcoded to avoid playback failures in DV manifests.
    private static func isAudioDirectStreamCapable(_ metadata: PlexMetadata) -> Bool {
        guard let audioCodec = metadata.Media?
            .first?
            .Part?
            .first?
            .Stream?
            .first(where: { $0.isAudio })?
            .codec?
            .lowercased() else {
            // Unknown codec - prefer safety and allow server to transcode to AAC
            return false
        }

        return ["aac", "ac3", "eac3"].contains(audioCodec)
    }

    private func bindPlayerState() {
        // Get the appropriate publisher based on player type
        let statePublisher: AnyPublisher<UniversalPlaybackState, Never>
        let timePublisher: AnyPublisher<TimeInterval, Never>
        let errorPublisher: AnyPublisher<PlayerError, Never>

        switch playerType {
        case .mpv:
            guard let mpv = mpvPlayerWrapper else { return }
            statePublisher = mpv.playbackStatePublisher
            timePublisher = mpv.timePublisher
            errorPublisher = mpv.errorPublisher
        case .avplayer:
            guard let avp = avPlayerWrapper else { return }
            statePublisher = avp.playbackStatePublisher
            timePublisher = avp.timePublisher
            errorPublisher = avp.errorPublisher
        }

        statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.playbackState = state
                self?.isBuffering = state == .buffering

                // Auto-hide controls when playing
                if state == .playing {
                    // Track that playback has started at least once (for HLS restart logic)
                    self?.hasPlaybackEverStarted = true
                    self?.startControlsHideTimer()
                    // Prevent screensaver during playback
                    UIApplication.shared.isIdleTimerDisabled = true
                    // Cancel paused poster timer and hide poster when resuming
                    self?.cancelPausedPosterTimer()
                } else {
                    self?.controlsTimer?.invalidate()
                    // Re-enable screensaver when not playing
                    if state == .paused || state == .ended || state == .idle {
                        UIApplication.shared.isIdleTimerDisabled = false
                    }
                    // Start paused poster timer when paused
                    if state == .paused {
                        self?.startPausedPosterTimer()
                    } else {
                        // Cancel timer for any other non-playing state
                        self?.cancelPausedPosterTimer()
                    }
                }

                // Handle video end - show post-video summary
                if state == .ended {
                    Task { await self?.handlePlaybackEnded() }
                }
            }
            .store(in: &cancellables)

        timePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                self.currentTime = time
                // Also update duration from wrapper
                switch self.playerType {
                case .mpv:
                    if let wrapper = self.mpvPlayerWrapper, wrapper.duration > 0 {
                        self.duration = wrapper.duration
                    }
                case .avplayer:
                    if let wrapper = self.avPlayerWrapper, wrapper.duration > 0 {
                        self.duration = wrapper.duration
                    }
                }
                // Check for markers at current time
                self.checkMarkers(at: time)
            }
            .store(in: &cancellables)

        errorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                self.errorMessage = error.localizedDescription

                // Handle AVPlayer errors with HLS restart or fallbacks
                if self.playerType == .avplayer {
                    print("🎬 [Error] AVPlayer failed: \(error.localizedDescription)")

                    // Check if this is a codec/rendering issue (likely DV HLS remux problem)
                    let isCodecError = if case .codecUnsupported = error { true } else { false }

                    Task {
                        // For codec/rendering errors with DV content, try HDR10 fallback first
                        // This is specifically for Plex's broken DV HLS remux from MKV sources
                        if isCodecError && self.isUsingDolbyVisionHLS && !self.hasAttemptedHDR10Fallback {
                            print("🎬 [Fallback] DV HLS rendering failed - attempting HDR10 base layer fallback...")
                            do {
                                try await self.fallbackToHDR10()
                                self.errorMessage = nil
                                print("🎬 [Fallback] HDR10 fallback successful!")
                                return
                            } catch {
                                print("🎬 [Fallback] HDR10 fallback failed: \(error.localizedDescription)")
                                // Fall through to MPV fallback
                            }
                        }

                        // If playback had previously started successfully (e.g., after pause/resume),
                        // try restarting the HLS session first before falling back to MPV
                        if self.hasPlaybackEverStarted && !self.hasAttemptedHLSRestart && !isCodecError {
                            print("🎬 [Restart] Playback was working before - attempting HLS session restart...")
                            do {
                                try await self.restartHLSSession()
                                self.errorMessage = nil
                                print("🎬 [Restart] HLS session restart successful!")
                                return
                            } catch {
                                print("🎬 [Restart] HLS restart failed: \(error.localizedDescription)")
                                // Fall through to MPV fallback
                            }
                        }

                        // Fall back to MPV if other fallbacks failed or weren't attempted
                        if !self.hasAttemptedMPVFallback {
                            print("🎬 [Fallback] Attempting fallback to MPV player...")
                            do {
                                try await self.fallbackToMPV()
                                self.errorMessage = nil
                            } catch {
                                print("🎬 [Fallback] MPV fallback also failed: \(error.localizedDescription)")
                            }
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // Auto-update tracks when player reports them
        if let mpv = mpvPlayerWrapper {
            mpv.tracksPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    self?.updateTrackLists()
                }
                .store(in: &cancellables)
        }

        if let avp = avPlayerWrapper {
            avp.tracksPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    self?.updateTrackLists()
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Computed Properties

    var isPlaying: Bool {
        switch playerType {
        case .mpv:
            return mpvPlayerWrapper?.isPlaying ?? false
        case .avplayer:
            return avPlayerWrapper?.isPlaying ?? false
        }
    }

    /// Log the selection decision to Sentry for debugging DV routing.
    private func addPlaybackSelectionBreadcrumb(reason: String) {
        let videoStreams = metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isVideo } ?? []
        let dvStream = videoStreams.first { ($0.DOVIProfile != nil) || ($0.DOVIPresent == true) }
        let audioStream = metadata.Media?.first?.Part?.first?.Stream?.first(where: { $0.isAudio })
        let breadcrumb = Breadcrumb(level: .info, category: "playback.selection")
        breadcrumb.message = "Playback selection (\(reason))"
        breadcrumb.data = [
            "player": playerType == .avplayer ? "avplayer" : "mpv",
            "has_dv": metadata.hasDolbyVision,
            "dv_profile": dvStream?.DOVIProfile ?? -1,
            "dv_bl_compat": dvStream?.DOVIBLCompatID ?? -1,
            "video_codec_id": dvStream?.codecID ?? "unknown",
            "video_codec": dvStream?.codec ?? "unknown",
            "audio_codec": audioStream?.codec ?? "unknown",
            "container": metadata.Media?.first?.container ?? "unknown",
            "allow_audio_direct_stream": allowAudioDirectStream
        ]
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    // MARK: - Playback Controls

    func startPlayback() async {
        guard let url = streamURL else {
            errorMessage = "No stream URL available"
            playbackState = .failed(.invalidURL)
            return
        }

        addPlaybackSelectionBreadcrumb(reason: "startPlayback")

        // Fetch detailed metadata with markers if not already present
        if metadata.Marker == nil || metadata.Marker?.isEmpty == true {
            print("⏭️ [Skip] No markers in initial metadata, fetching detailed metadata...")
            await fetchMarkersIfNeeded()
        }

        // Log marker info at playback start
        if let intro = metadata.introMarker {
            print("⏭️ [Skip] Intro marker found: \(intro.startTimeSeconds)s - \(intro.endTimeSeconds)s")
        }
        if let credits = metadata.creditsMarker {
            print("⏭️ [Skip] Credits marker found: \(credits.startTimeSeconds)s - \(credits.endTimeSeconds)s")
        }
        if metadata.Marker == nil || metadata.Marker?.isEmpty == true {
            print("⏭️ [Skip] No markers found in metadata (even after fetch)")
        }

        do {
            switch playerType {
            case .mpv:
                guard let mpv = mpvPlayerWrapper else { return }

                // Configure display criteria to enable Match Frame Rate and Match Dynamic Range
                // For DV content, MPV plays HDR10 fallback (can't decode DV enhancement layer)
                #if os(tvOS)
                DisplayCriteriaManager.shared.configureForContent(
                    videoStream: metadata.primaryVideoStream,
                    forceHDR10Fallback: metadata.hasDolbyVision  // MPV can't play DV
                )
                #endif

                try await mpv.load(url: url, headers: streamHeaders, startTime: startOffset)
                mpv.play()
                self.duration = mpv.duration
                updateTrackLists()

            case .avplayer:
                guard let avp = avPlayerWrapper else { return }

                // Set expected aspect ratio from source metadata for verification
                if let videoStream = metadata.Media?.first?.Part?.first?.Stream?.first(where: { $0.isVideo }),
                   let width = videoStream.width, let height = videoStream.height, height > 0 {
                    avp.setExpectedAspectRatio(width: width, height: height)
                }

                // Only do HLS preflight check for transcode URLs (not direct play)
                let isHLSStream = url.absoluteString.contains(".m3u8")
                if isHLSStream {
                    // Wait for HLS transcode to be ready before loading
                    // Plex needs time to start the transcode session and generate segments
                    print("🎬 [AVPlayer] Waiting for HLS transcode session...")
                    let transcodeReady = await waitForHLSTranscodeReady(url: url, headers: streamHeaders)
                    if !transcodeReady {
                        throw PlayerError.loadFailed("HLS transcode session failed to start")
                    }
                    print("🎬 [AVPlayer] Transcode ready, loading stream...")
                } else {
                    print("🎬 [AVPlayer] Direct play URL detected, skipping HLS preflight")
                }

                // For AVPlayer, seek to start offset after loading if needed
                try await avp.load(url: url, headers: streamHeaders)
                if let offset = startOffset, offset > 0 {
                    await avp.seek(to: offset)
                }
                avp.play()
                self.duration = avp.duration
            }

            // Preload thumbnails for scrubbing
            preloadThumbnails()

            startControlsHideTimer()
        } catch {
            // If AVPlayer failed, try falling back to MPV
            if playerType == .avplayer {
                print("🎬 [Fallback] AVPlayer failed to load: \(error.localizedDescription)")
                print("🎬 [Fallback] Attempting fallback to MPV player...")

                // Capture the AVPlayer failure to Sentry before fallback
                SentrySDK.capture(error: error) { scope in
                    scope.setTag(value: "playback", key: "component")
                    scope.setTag(value: "avplayer", key: "player_type")
                    scope.setTag(value: "fallback_triggered", key: "fallback_status")
                    scope.setExtra(value: url.absoluteString, key: "stream_url")
                    scope.setExtra(value: self.metadata.title ?? "unknown", key: "media_title")
                    scope.setExtra(value: self.metadata.type ?? "unknown", key: "media_type")
                    scope.setExtra(value: self.metadata.ratingKey ?? "unknown", key: "rating_key")
                    scope.setExtra(value: self.startOffset ?? 0, key: "start_offset")
                }

                // Attempt MPV fallback
                do {
                    try await fallbackToMPV()
                    return  // Success - don't show error
                } catch {
                    print("🎬 [Fallback] MPV fallback also failed: \(error.localizedDescription)")
                    // Fall through to show the original error
                }
            }

            errorMessage = error.localizedDescription
            playbackState = .failed(.loadFailed(error.localizedDescription))

            // Capture playback load failure to Sentry
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "playback", key: "component")
                scope.setTag(value: self.playerType == .avplayer ? "avplayer" : "mpv", key: "player_type")
                scope.setExtra(value: url.absoluteString, key: "stream_url")
                scope.setExtra(value: self.metadata.title ?? "unknown", key: "media_title")
                scope.setExtra(value: self.metadata.type ?? "unknown", key: "media_type")
                scope.setExtra(value: self.metadata.ratingKey ?? "unknown", key: "rating_key")
                scope.setExtra(value: self.startOffset ?? 0, key: "start_offset")
            }
        }
    }

    // MARK: - HLS Transcode Preflight

    /// Wait for the HLS transcode session to be ready before loading into AVPlayer
    /// Plex needs time to start the transcoder and generate the initial manifest AND segments
    /// This method verifies both the manifest and at least one segment are accessible
    /// - Parameters:
    ///   - url: The HLS manifest URL
    ///   - headers: HTTP headers including auth token
    /// - Returns: true if the transcode is ready, false if it failed to start
    private func waitForHLSTranscodeReady(url: URL, headers: [String: String]) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        // Add auth headers
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        // Try up to 8 times with delays to give Plex time to start the transcode
        for attempt in 1...8 {
            do {
                print("🎬 [AVPlayer] Preflight attempt \(attempt)/8: Checking HLS manifest...")

                let (data, response) = try await URLSession.shared.data(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    print("🎬 [AVPlayer] Preflight response: \(httpResponse.statusCode) (\(data.count) bytes)")

                    if httpResponse.statusCode == 200 && data.count > 0 {
                        if let content = String(data: data, encoding: .utf8) {
                            // Check for valid HLS manifest with actual content
                            let hasHeader = content.contains("#EXTM3U")
                            let hasVariants = content.contains(".m3u8")
                            let hasSegments = content.contains("#EXTINF")

                            if hasHeader && hasVariants {
                                // This is a master playlist - follow a variant to check for segments
                                print("🎬 [AVPlayer] Preflight: Master playlist found, checking variant...")
                                if let variantReady = await checkVariantPlaylist(masterContent: content, baseURL: url, headers: headers), variantReady {
                                    print("🎬 [AVPlayer] Preflight: Variant playlist has segments, transcode ready!")
                                    return true
                                } else {
                                    print("🎬 [AVPlayer] Preflight: Variant not ready yet...")
                                }
                            } else if hasHeader && hasSegments {
                                // This is already a media playlist with segments
                                print("🎬 [AVPlayer] Preflight: Media playlist with segments found")
                                return true
                            } else if hasHeader {
                                // Has header but no content yet
                                print("🎬 [AVPlayer] Preflight: Manifest exists but no content yet, waiting...")
                            } else {
                                print("🎬 [AVPlayer] Preflight: Invalid manifest content")
                            }
                        }
                    } else if httpResponse.statusCode == 404 || httpResponse.statusCode == 503 {
                        // Transcode not started yet
                        print("🎬 [AVPlayer] Preflight: Transcode not ready (\(httpResponse.statusCode))")
                    } else {
                        print("🎬 [AVPlayer] Preflight: Unexpected status \(httpResponse.statusCode)")
                    }
                }
            } catch {
                print("🎬 [AVPlayer] Preflight error: \(error.localizedDescription)")
            }

            // Wait before retrying (increasing delay: 0.5s, 1s, 1.5s, 2s, 2.5s, 3s, 3.5s, 4s)
            if attempt < 8 {
                let delay = Double(attempt) * 0.5
                print("🎬 [AVPlayer] Preflight: Waiting \(delay)s before retry...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        print("🎬 [AVPlayer] Preflight: Transcode failed to start after 8 attempts")
        return false
    }

    /// Check if a variant playlist has actual segments ready
    private func checkVariantPlaylist(masterContent: String, baseURL: URL, headers: [String: String]) async -> Bool? {
        // Parse the master playlist to find a variant playlist URL
        let lines = masterContent.components(separatedBy: .newlines)
        var variantURL: URL?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(".m3u8") && !trimmed.hasPrefix("#") {
                // Construct the full URL for the variant
                if let url = URL(string: trimmed, relativeTo: baseURL) {
                    variantURL = url.absoluteURL
                    break
                }
            }
        }

        guard let variant = variantURL else {
            print("🎬 [AVPlayer] Preflight: No variant playlist URL found in master")
            return nil
        }

        print("🎬 [AVPlayer] Preflight: Checking variant at \(variant.lastPathComponent)")

        var request = URLRequest(url: variant)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               let content = String(data: data, encoding: .utf8) {

                // Check if variant playlist has actual segments
                let hasSegments = content.contains("#EXTINF")
                let hasMediaContent = content.contains(".mp4") || content.contains(".ts") || content.contains(".m4s")

                if hasSegments && hasMediaContent {
                    print("🎬 [AVPlayer] Preflight: Variant has \(content.components(separatedBy: "#EXTINF").count - 1) segments")
                    return true
                } else {
                    print("🎬 [AVPlayer] Preflight: Variant exists but has no segments yet")
                    return false
                }
            } else {
                print("🎬 [AVPlayer] Preflight: Variant not accessible")
                return false
            }
        } catch {
            print("🎬 [AVPlayer] Preflight: Failed to fetch variant: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - AVPlayer HLS Restart and Fallbacks

    /// Tracks whether we've already attempted HLS session restart (to prevent loops)
    private var hasAttemptedHLSRestart = false

    /// Tracks whether we've already attempted HDR10 fallback for DV content (to prevent loops)
    private var hasAttemptedHDR10Fallback = false

    /// Tracks whether we're currently using DV mode (useDoviCodecs=1) for HLS
    private var isUsingDolbyVisionHLS = false

    /// Tracks whether we've already attempted fallback (to prevent loops)
    private var hasAttemptedMPVFallback = false

    /// Tracks whether playback has successfully started at least once
    /// Used to distinguish initial load failures from mid-playback failures (e.g., after pause)
    private var hasPlaybackEverStarted = false

    /// Restart the HLS session when it expires (e.g., after long pause)
    /// This re-requests the HLS URL from Plex and reloads AVPlayer at the same position
    private func restartHLSSession() async throws {
        guard !hasAttemptedHLSRestart else {
            throw PlayerError.loadFailed("Already attempted HLS restart")
        }
        hasAttemptedHLSRestart = true

        // Save current position to restore after restart
        let savedPosition = currentTime
        print("🎬 [Restart] Saving position: \(savedPosition)s")

        // Stop current AVPlayer
        avPlayerWrapper?.stop()
        avPlayerWrapper = nil

        // Create new AVPlayer instance
        let newAVPlayer = AVPlayerWrapper()
        avPlayerWrapper = newAVPlayer

        // Rebind to new player's publishers
        cancellables.removeAll()
        bindPlayerState()

        // Rebuild HLS URL with current position as offset
        let networkManager = PlexNetworkManager.shared
        guard let ratingKey = metadata.ratingKey else {
            throw PlayerError.loadFailed("Missing rating key")
        }

        if let result = networkManager.buildHLSDirectPlayURL(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: ratingKey,
            offsetMs: Int(savedPosition * 1000),
            hasHDR: metadata.hasHDR,
            // No transcoding — rely on DV remux and codec tag fixes
            forceVideoTranscode: false,
            allowAudioDirectStream: allowAudioDirectStream
        ) {
            streamURL = result.url
            streamHeaders = result.headers
        } else {
            throw PlayerError.loadFailed("Could not build HLS URL")
        }

        guard let url = streamURL else {
            throw PlayerError.loadFailed("No stream URL available")
        }

        print("🎬 [Restart] Loading new HLS session: \(url.absoluteString.prefix(100))...")

        // Load the new stream (offset is already baked into the HLS URL)
        // Warm up the transcode session to avoid 404s on initial segments
        let isHLS = url.absoluteString.contains(".m3u8")
        if isHLS {
            print("🎬 [Restart] Waiting for HLS transcode session...")
            let ready = await waitForHLSTranscodeReady(url: url, headers: streamHeaders)
            if !ready {
                throw PlayerError.loadFailed("HLS transcode session failed to start on restart")
            }
        }

        try await newAVPlayer.load(url: url, headers: streamHeaders, isLive: false)
        newAVPlayer.play()

        // Update duration from new player
        if newAVPlayer.duration > 0 {
            duration = newAVPlayer.duration
        }

        updateTrackLists()
        startControlsHideTimer()

        // Show brief notice to user
        showCompatibilityNotice("Stream restarted")

        print("🎬 [Restart] HLS session restart complete, resuming from \(savedPosition)s")
    }

    /// Fall back from Dolby Vision HLS to HDR10 base layer when DV remux fails
    /// This is a workaround for Plex's broken DV HLS remux from MKV sources
    /// By requesting without useDoviCodecs=1, we get the HDR10 base layer which AVPlayer can handle
    private func fallbackToHDR10() async throws {
        guard !hasAttemptedHDR10Fallback else {
            throw PlayerError.loadFailed("Already attempted HDR10 fallback")
        }
        hasAttemptedHDR10Fallback = true
        isUsingDolbyVisionHLS = false

        // Save current position to restore after restart
        let savedPosition = currentTime
        print("🎬 [HDR10 Fallback] Saving position: \(savedPosition)s")

        // Stop current AVPlayer
        avPlayerWrapper?.stop()
        avPlayerWrapper = nil

        // Create new AVPlayer instance
        let newAVPlayer = AVPlayerWrapper()
        avPlayerWrapper = newAVPlayer

        // Set expected aspect ratio for the new player
        if let videoStream = metadata.Media?.first?.Part?.first?.Stream?.first(where: { $0.isVideo }),
           let width = videoStream.width, let height = videoStream.height, height > 0 {
            newAVPlayer.setExpectedAspectRatio(width: width, height: height)
        }

        // Rebind to new player's publishers
        cancellables.removeAll()
        bindPlayerState()

        // Rebuild HLS URL WITHOUT useDoviCodecs - get HDR10 base layer only
        let networkManager = PlexNetworkManager.shared
        guard let ratingKey = metadata.ratingKey else {
            throw PlayerError.loadFailed("Missing rating key")
        }

        print("🎬 [HDR10 Fallback] Requesting HLS without DV codecs (HDR10 base layer)...")

        if let result = networkManager.buildHLSDirectPlayURL(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: ratingKey,
            offsetMs: Int(savedPosition * 1000),
            hasHDR: metadata.hasHDR,
            useDolbyVision: false,  // Key difference: no useDoviCodecs=1
            forceVideoTranscode: false,
            allowAudioDirectStream: allowAudioDirectStream
        ) {
            streamURL = result.url
            streamHeaders = result.headers
        } else {
            throw PlayerError.loadFailed("Could not build HDR10 HLS URL")
        }

        guard let url = streamURL else {
            throw PlayerError.loadFailed("No stream URL available")
        }

        print("🎬 [HDR10 Fallback] Loading HDR10 stream: \(url.absoluteString.prefix(100))...")

        // Warm up the HLS transcode (HDR10) before loading to avoid 404s
        if url.absoluteString.contains(".m3u8") {
            print("🎬 [HDR10 Fallback] Waiting for HLS transcode session...")
            let ready = await waitForHLSTranscodeReady(url: url, headers: streamHeaders)
            if !ready {
                throw PlayerError.loadFailed("HLS transcode session failed to start for HDR10 fallback")
            }
        }

        // Load the new stream
        try await newAVPlayer.load(url: url, headers: streamHeaders, isLive: false)
        newAVPlayer.play()

        // Update duration from new player
        if newAVPlayer.duration > 0 {
            duration = newAVPlayer.duration
        }

        updateTrackLists()
        startControlsHideTimer()

        // Show notice explaining the fallback (this is a Plex issue, not our bug)
        showCompatibilityNotice("Playing HDR10 (Plex can't remux DV from MKV)")

        print("🎬 [HDR10 Fallback] Complete, resuming from \(savedPosition)s")
    }

    /// Fall back from AVPlayer to MPV when AVPlayer fails to load
    /// This creates an MPV player, rebuilds the stream URL for direct play, and retries
    private func fallbackToMPV() async throws {
        guard !hasAttemptedMPVFallback else {
            throw PlayerError.loadFailed("Already attempted MPV fallback")
        }
        hasAttemptedMPVFallback = true

        // Stop AVPlayer
        avPlayerWrapper?.stop()
        avPlayerWrapper = nil

        // Switch to MPV
        playerType = .mpv
        mpvPlayerWrapper = MPVPlayerWrapper()

        // Cancel existing subscriptions and rebind to MPV
        cancellables.removeAll()
        bindPlayerState()

        // Rebuild stream URL for MPV (direct play instead of HLS)
        let networkManager = PlexNetworkManager.shared
        guard let ratingKey = metadata.ratingKey else {
            throw PlayerError.loadFailed("Missing rating key")
        }

        let partKey = metadata.Media?.first?.Part?.first?.key

        if let partKey = partKey {
            streamURL = networkManager.buildVLCDirectPlayURL(
                serverURL: serverURL,
                authToken: authToken,
                partKey: partKey
            )
        } else {
            streamURL = networkManager.buildDirectStreamURL(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey,
                offsetMs: Int((startOffset ?? 0) * 1000),
                isAudio: false
            )
        }

        streamHeaders = [
            "X-Plex-Token": authToken,
            "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
            "X-Plex-Platform": PlexAPI.platform,
            "X-Plex-Device": PlexAPI.deviceName,
            "X-Plex-Product": PlexAPI.productName
        ]

        guard let url = streamURL else {
            throw PlayerError.loadFailed("Could not build MPV stream URL")
        }

        print("🎬 [Fallback] Retrying with MPV using URL: \(url.absoluteString)")

        // Show notice to user about the fallback
        // Use appropriate message based on which setting was enabled
        let useAVPlayerForAll = UserDefaults.standard.bool(forKey: "useAVPlayerForAllVideos")
        if useAVPlayerForAll {
            showCompatibilityNotice("AVPlayer failed — falling back to MPV")
        } else {
            showCompatibilityNotice("AVPlayer failed — falling back to standard HDR")
        }

        // Load and play with MPV
        guard let mpv = mpvPlayerWrapper else {
            throw PlayerError.loadFailed("MPV player not available")
        }

        // Configure display criteria to enable Match Frame Rate and Match Dynamic Range
        // For DV content, MPV plays HDR10 fallback (can't decode DV enhancement layer)
        #if os(tvOS)
        DisplayCriteriaManager.shared.configureForContent(
            videoStream: metadata.primaryVideoStream,
            forceHDR10Fallback: metadata.hasDolbyVision  // MPV can't play DV
        )
        #endif

        try await mpv.load(url: url, headers: streamHeaders, startTime: startOffset)
        mpv.play()
        self.duration = mpv.duration
        updateTrackLists()

        preloadThumbnails()
        startControlsHideTimer()

        print("🎬 [Fallback] MPV fallback successful!")
    }

    /// Called when the MPV view controller is created
    func setPlayerController(_ controller: MPVMetalViewController) {
        mpvPlayerWrapper?.setPlayerController(controller)
    }

    func stopPlayback() {
        switch playerType {
        case .mpv:
            mpvPlayerWrapper?.stop()
        case .avplayer:
            avPlayerWrapper?.stop()
        }
        controlsTimer?.invalidate()
        hideCompatibilityNotice()

        // Reset display criteria to default (allows TV to return to normal mode)
        #if os(tvOS)
        DisplayCriteriaManager.shared.reset()
        #endif

        // Re-enable screensaver
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func togglePlayPause() {
        hidePausedPoster()
        switch playerType {
        case .mpv:
            if mpvPlayerWrapper?.isPlaying == true {
                mpvPlayerWrapper?.pause()
            } else {
                mpvPlayerWrapper?.play()
            }
        case .avplayer:
            if avPlayerWrapper?.isPlaying == true {
                avPlayerWrapper?.pause()
            } else {
                avPlayerWrapper?.play()
            }
        }
        showControlsTemporarily()
    }

    /// Resume playback (used by remote commands)
    func resume() {
        pausedDueToAppInactive = false  // User explicitly resumed, allow normal playback
        hidePausedPoster()
        switch playerType {
        case .mpv:
            mpvPlayerWrapper?.play()
        case .avplayer:
            avPlayerWrapper?.play()
        }
        showControlsTemporarily()
    }

    /// Pause playback (used by remote commands)
    func pause() {
        switch playerType {
        case .mpv:
            mpvPlayerWrapper?.pause()
        case .avplayer:
            avPlayerWrapper?.pause()
        }
        showControlsTemporarily()
    }

    // MARK: - Info Panel Navigation

    /// Reset settings panel state when opening
    func resetSettingsPanel() {
        // Refresh track lists when panel opens
        updateTrackLists()
        focusedColumn = 0
        focusedRowIndex = 0
    }

    func seek(to time: TimeInterval) async {
        switch playerType {
        case .mpv:
            await mpvPlayerWrapper?.seek(to: time)
        case .avplayer:
            await avPlayerWrapper?.seek(to: time)
        }
        showControlsTemporarily()
    }

    func seekRelative(by seconds: TimeInterval) async {
        hidePausedPoster()
        switch playerType {
        case .mpv:
            await mpvPlayerWrapper?.seekRelative(by: seconds)
        case .avplayer:
            // AVPlayer doesn't have seekRelative, so calculate new time
            let newTime = max(0, min(duration, currentTime + seconds))
            await avPlayerWrapper?.seek(to: newTime)
        }
        showControlsTemporarily()

        // Show seek indicator for tap-to-skip
        let intSeconds = Int(abs(seconds))
        showSeekIndicator(seconds >= 0 ? .forward(intSeconds) : .backward(intSeconds))
    }

    /// Show seek indicator briefly (1.5 seconds)
    private func showSeekIndicator(_ indicator: SeekIndicator) {
        seekIndicatorTimer?.invalidate()
        withAnimation(.easeOut(duration: 0.15)) {
            seekIndicator = indicator
        }
        seekIndicatorTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                withAnimation(.easeOut(duration: 0.25)) {
                    self?.seekIndicator = nil
                }
            }
        }
    }

    // MARK: - Scrubbing

    /// Speed multipliers for each level (seconds per 100ms tick)
    private static let scrubSpeeds: [Int: TimeInterval] = [
        1: 1.0,    // 1x = 10 seconds per second
        2: 2.0,    // 2x = 20 seconds per second
        3: 4.0,    // 3x = 40 seconds per second
        4: 8.0,    // 4x = 80 seconds per second
        5: 15.0,   // 5x = 150 seconds per second
        6: 30.0,   // 6x = 300 seconds per second (5 min/sec)
        7: 45.0,   // 7x = 450 seconds per second (7.5 min/sec)
        8: 60.0    // 8x = 600 seconds per second (10 min/sec)
    ]

    /// Human-readable label for current scrub speed
    var scrubStepLabel: String? {
        guard scrubSpeed != 0 else { return nil }
        let magnitude = abs(scrubSpeed)
        let arrow = scrubSpeed > 0 ? "▶▶" : "◀◀"
        return "\(arrow) \(magnitude)×"
    }

    /// Start or increase scrub speed in given direction
    /// Each click increases speed up to 8x
    /// - Parameter forward: true for forward, false for backward
    func scrubInDirection(forward: Bool) {
        hidePausedPoster()
        let direction = forward ? 1 : -1

        if !isScrubbing {
            // Start scrubbing
            isScrubbing = true
            scrubTime = currentTime
            scrubSpeed = direction  // Start at 1x
            controlsTimer?.invalidate()
            startScrubTimer()
            loadThumbnail(for: scrubTime)
        } else if (scrubSpeed > 0) == forward {
            // Same direction - increase speed up to 8x
            let newSpeed = min(8, abs(scrubSpeed) + 1) * direction
            scrubSpeed = newSpeed
        } else {
            // Opposite direction - decelerate first, then reverse
            if abs(scrubSpeed) > 1 {
                // Slow down by 1 level, keep same direction
                let currentDirection = scrubSpeed > 0 ? 1 : -1
                scrubSpeed = (abs(scrubSpeed) - 1) * currentDirection
            } else {
                // At 1x, switch to opposite direction at 1x
                scrubSpeed = direction
            }
        }

        // Immediate jump on each press
        let jumpAmount: TimeInterval = forward ? 10 : -10
        scrubTime = max(0, min(duration, scrubTime + jumpAmount))
        loadThumbnail(for: scrubTime)
    }

    func startScrubbing() {
        isScrubbing = true
        scrubTime = currentTime
        scrubSpeed = 0
        controlsTimer?.invalidate()
        loadThumbnail(for: scrubTime)
    }

    /// Start swipe-based scrubbing (proportional, no speed acceleration)
    func startSwipeScrubbing() {
        hidePausedPoster()
        isScrubbing = true
        scrubTime = currentTime
        scrubSpeed = 0  // No direction-based speed for swipe scrubbing
        scrubStartTime = nil  // No time-based acceleration for swipe
        controlsTimer?.invalidate()
        loadThumbnail(for: scrubTime)
    }

    /// Update scrub position by a relative amount (for swipe gestures)
    /// - Parameter seconds: Amount to seek (positive = forward, negative = backward)
    func updateSwipeScrubPosition(by seconds: TimeInterval) {
        if !isScrubbing {
            startSwipeScrubbing()
        }
        scrubTime = max(0, min(duration, scrubTime + seconds))
        loadThumbnail(for: scrubTime)
    }

    /// Handle click wheel rotation (iPod-style circular scrubbing)
    /// - Parameter radians: Rotation amount in radians (clockwise/positive = forward)
    func handleWheelRotation(_ radians: Float) {
        // Convert rotation to seek time
        // ~10 seconds per full rotation (2π radians), so ~1.6 seconds per radian
        let secondsPerRadian: TimeInterval = 10.0
        let seekDelta = TimeInterval(radians) * secondsPerRadian

        if !isScrubbing {
            hidePausedPoster()
            isScrubbing = true
            scrubTime = currentTime
            scrubSpeed = 0
            scrubStartTime = nil  // No time-based acceleration for wheel
            controlsTimer?.invalidate()
        }

        scrubTime = max(0, min(duration, scrubTime + seekDelta))
        loadThumbnail(for: scrubTime)
    }

    func updateScrubPosition(_ time: TimeInterval) {
        scrubTime = max(0, min(duration, time))
        loadThumbnail(for: scrubTime)
    }

    func scrubRelative(by seconds: TimeInterval) {
        if !isScrubbing {
            startScrubbing()
        }
        scrubTime = max(0, min(duration, scrubTime + seconds))
        loadThumbnail(for: scrubTime)
    }

    func commitScrub() async {
        stopScrubTimer()
        if isScrubbing {
            await seek(to: scrubTime)
            isScrubbing = false
            scrubSpeed = 0
            scrubStartTime = nil
            scrubThumbnail = nil
        }
    }

    func cancelScrub() {
        stopScrubTimer()
        isScrubbing = false
        scrubSpeed = 0
        scrubStartTime = nil
        scrubTime = currentTime
        scrubThumbnail = nil
        startControlsHideTimer()
    }

    private func startScrubTimer() {
        scrubTimer?.invalidate()
        scrubTimer = Timer.scheduledTimer(withTimeInterval: scrubUpdateInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updateScrubFromTimer()
            }
        }
    }

    private func stopScrubTimer() {
        scrubTimer?.invalidate()
        scrubTimer = nil
    }

    private func updateScrubFromTimer() {
        guard isScrubbing, scrubSpeed != 0 else { return }

        let speedMagnitude = abs(scrubSpeed)
        let direction: TimeInterval = scrubSpeed > 0 ? 1 : -1
        let secondsPerTick = Self.scrubSpeeds[speedMagnitude] ?? 1.0

        let newTime = scrubTime + (secondsPerTick * direction)
        scrubTime = max(0, min(duration, newTime))

        // Stop at boundaries
        if scrubTime <= 0 || scrubTime >= duration {
            scrubSpeed = 0
            scrubStartTime = nil
            stopScrubTimer()
        }

        loadThumbnail(for: scrubTime)
    }

    private func loadThumbnail(for time: TimeInterval) {
        guard let partId = metadata.Media?.first?.Part?.first?.id else {
            print("⚠️ No part ID available for thumbnails")
            return
        }

        Task {
            let thumbnail = await PlexThumbnailService.shared.getThumbnail(
                partId: partId,
                time: time,
                serverURL: serverURL,
                authToken: authToken
            )
            self.scrubThumbnail = thumbnail
        }
    }

    /// Preload thumbnails when playback starts
    func preloadThumbnails() {
        // Debug: Log metadata structure
        if let media = metadata.Media {
            //print("🖼️ [THUMB] Media count: \(media.count)")
            if let firstMedia = media.first {
                //print("🖼️ [THUMB] First media id: \(firstMedia.id)")
                if let parts = firstMedia.Part {
                    //print("🖼️ [THUMB] Part count: \(parts.count)")
                    if let firstPart = parts.first {
                        //print("🖼️ [THUMB] First part id: \(firstPart.id)")
                    }
                } else {
                    print("⚠️ [THUMB] No Part array in media")
                }
            }
        } else {
            print("⚠️ [THUMB] No Media array in metadata")
        }

        guard let partId = metadata.Media?.first?.Part?.first?.id else {
            print("⚠️ No part ID available for thumbnail preload")
            return
        }
        // print("🖼️ Preloading BIF thumbnails for part \(partId)")
        PlexThumbnailService.shared.preloadBIF(
            partId: partId,
            serverURL: serverURL,
            authToken: authToken
        )
    }

    // MARK: - Track Selection

    func selectAudioTrack(id: Int) {
        // Select on the active player
        if mpvPlayerWrapper != nil {
            mpvPlayerWrapper?.selectAudioTrack(id: id)
        } else if avPlayerWrapper != nil {
            avPlayerWrapper?.selectAudioTrack(id: id)
        }
        currentAudioTrackId = id

        // Save preference
        if let track = audioTracks.first(where: { $0.id == id }) {
            AudioPreferenceManager.current = AudioPreference(from: track)
            print("[AUDIO PREF] Saved: \(track.languageCode ?? "?")")
        }
    }

    /// Select audio track without saving preference (for auto-selection)
    private func selectAudioTrackWithoutSaving(id: Int) {
        if mpvPlayerWrapper != nil {
            mpvPlayerWrapper?.selectAudioTrack(id: id)
        } else if avPlayerWrapper != nil {
            avPlayerWrapper?.selectAudioTrack(id: id)
        }
        currentAudioTrackId = id
    }

    func selectSubtitleTrack(id: Int?) {
        // Select on the active player
        if mpvPlayerWrapper != nil {
            mpvPlayerWrapper?.selectSubtitleTrack(id: id)
        } else if avPlayerWrapper != nil {
            avPlayerWrapper?.selectSubtitleTrack(id: id)
        }
        currentSubtitleTrackId = id

        // Save preference
        if let id = id, let track = subtitleTracks.first(where: { $0.id == id }) {
            SubtitlePreferenceManager.current = SubtitlePreference(from: track)
            print("🎬 [SUBTITLE PREF] Saved: \(track.languageCode ?? "?") / \(track.codec ?? "?")")
        } else {
            SubtitlePreferenceManager.current = .off
            print("🎬 [SUBTITLE PREF] Saved: Off")
        }
    }

    /// Whether we've already applied track preferences for this playback session
    private var hasAppliedSubtitlePreference = false
    private var hasAppliedAudioPreference = false

    private func updateTrackLists() {
        let previousSubtitleCount = subtitleTracks.count
        let previousAudioCount = audioTracks.count

        var newAudioTracks: [MediaTrack]
        var newSubtitleTracks: [MediaTrack]
        var newCurrentAudioTrackId: Int?
        var newCurrentSubtitleTrackId: Int?

        // Get tracks from the active player
        if let mpv = mpvPlayerWrapper {
            newAudioTracks = mpv.audioTracks
            newSubtitleTracks = mpv.subtitleTracks
            newCurrentAudioTrackId = mpv.currentAudioTrackId
            newCurrentSubtitleTrackId = mpv.currentSubtitleTrackId
        } else if let avp = avPlayerWrapper {
            newAudioTracks = avp.audioTracks
            newSubtitleTracks = avp.subtitleTracks
            newCurrentAudioTrackId = avp.currentAudioTrackId
            newCurrentSubtitleTrackId = avp.currentSubtitleTrackId
        } else {
            // No active player
            return
        }

        // Enrich with Plex stream metadata (for channel info, etc.)
        if let streams = metadata.Media?.first?.Part?.first?.Stream {
            newAudioTracks = enrichTracksWithPlexStreams(newAudioTracks, plexStreams: streams)
            newSubtitleTracks = enrichTracksWithPlexStreams(newSubtitleTracks, plexStreams: streams)
        }

        audioTracks = newAudioTracks
        subtitleTracks = newSubtitleTracks
        currentAudioTrackId = newCurrentAudioTrackId
        currentSubtitleTrackId = newCurrentSubtitleTrackId

        // Apply saved audio preference when tracks are first available
        if !hasAppliedAudioPreference && !audioTracks.isEmpty && previousAudioCount == 0 {
            hasAppliedAudioPreference = true
            applyAudioPreference()
        }

        // Apply saved subtitle preference when tracks are first available
        if !hasAppliedSubtitlePreference && !subtitleTracks.isEmpty && previousSubtitleCount == 0 {
            hasAppliedSubtitlePreference = true
            applySubtitlePreference()
        }
    }

    /// Enrich MPV tracks with Plex stream metadata (channels, etc.)
    private func enrichTracksWithPlexStreams(_ tracks: [MediaTrack], plexStreams: [PlexStream]) -> [MediaTrack] {
        return tracks.map { track in
            // Try to find matching Plex stream by language code and codec
            let matchingStream = plexStreams.first { stream in
                // Match by language code and codec type
                let langMatch = track.languageCode?.lowercased() == stream.languageCode?.lowercased()
                let codecMatch = track.codec?.lowercased() == stream.codec?.lowercased()
                return langMatch && codecMatch
            } ?? plexStreams.first { stream in
                // Fallback: just match by language
                track.languageCode?.lowercased() == stream.languageCode?.lowercased()
            }

            guard let stream = matchingStream else { return track }

            // Create enriched track with Plex channel info
            return MediaTrack(
                id: track.id,
                name: track.name,
                language: track.language,
                languageCode: track.languageCode,
                codec: track.codec,
                isDefault: track.isDefault,
                isForced: track.isForced,
                isHearingImpaired: stream.hearingImpaired ?? track.isHearingImpaired,
                channels: stream.channels ?? track.channels
            )
        }
    }

    /// Apply saved audio preference
    private func applyAudioPreference() {
        let preference = AudioPreferenceManager.current

        // Find best matching track
        if let match = AudioPreferenceManager.findBestMatch(in: audioTracks, preference: preference) {
            if match.id != currentAudioTrackId {
                selectAudioTrackWithoutSaving(id: match.id)
                print("[AUDIO PREF] Applied: \(match.audioFormatString) (\(match.languageCode ?? "?"))")
            } else {
                print("[AUDIO PREF] Already on best track: \(match.audioFormatString)")
            }
        }
    }

    /// Apply saved subtitle preference
    private func applySubtitlePreference() {
        let preference = SubtitlePreferenceManager.current

        if !preference.enabled {
            // User prefers subtitles off
            selectSubtitleTrackWithoutSaving(id: nil)
            print("🎬 [SUBTITLE PREF] Applied: Off (user preference)")
            return
        }

        // Find best matching track
        if let match = SubtitlePreferenceManager.findBestMatch(in: subtitleTracks, preference: preference) {
            selectSubtitleTrackWithoutSaving(id: match.id)
            print("🎬 [SUBTITLE PREF] Applied: \(match.name) (matched \(preference.languageCode ?? "?"))")
        } else {
            // No matching language found - keep subtitles off
            selectSubtitleTrackWithoutSaving(id: nil)
            print("🎬 [SUBTITLE PREF] Applied: Off (no \(preference.languageCode ?? "?") tracks found)")
        }
    }

    /// Select subtitle track without saving preference (for auto-selection)
    private func selectSubtitleTrackWithoutSaving(id: Int?) {
        mpvPlayerWrapper?.selectSubtitleTrack(id: id)
        currentSubtitleTrackId = id
    }

    // MARK: - Controls Visibility

    func showControlsTemporarily() {
        showControls = true
        startControlsHideTimer()
    }

    private func startControlsHideTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: controlsHideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            let isPlaying = self.playbackState == .playing
            Task { @MainActor [weak self] in
                guard let self, isPlaying else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    self.showControls = false
                }
            }
        }
    }

    // MARK: - Compatibility Notice

    private func showCompatibilityNotice(_ message: String) {
        compatibilityNotice = message
        compatibilityNoticeTimer?.invalidate()
        compatibilityNoticeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.compatibilityNotice = nil
        }
    }

    private func hideCompatibilityNotice() {
        compatibilityNoticeTimer?.invalidate()
        compatibilityNoticeTimer = nil
        compatibilityNotice = nil
    }

    // MARK: - Paused Poster Timer

    /// Start timer to show poster after being paused for 5 seconds
    private func startPausedPosterTimer() {
        pausedPosterTimer?.invalidate()
        pausedPosterTimer = Timer.scheduledTimer(withTimeInterval: pausedPosterDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackState == .paused else { return }
                withAnimation(.easeIn(duration: 1.0)) {
                    self.showPausedPoster = true
                }
            }
        }
    }

    /// Cancel paused poster timer and hide the poster
    private func cancelPausedPosterTimer() {
        pausedPosterTimer?.invalidate()
        pausedPosterTimer = nil
        if showPausedPoster {
            withAnimation(.easeOut(duration: 0.5)) {
                showPausedPoster = false
            }
        }
    }

    /// Hide paused poster on any control input
    func hidePausedPoster() {
        cancelPausedPosterTimer()
    }

    // MARK: - Marker Detection & Skipping

    /// How many seconds before a marker to show the skip button
    private let markerPreviewTime: TimeInterval = 5.0

    /// Check if current time is within a marker range (or approaching one)
    /// Also triggers post-video summary at credits marker or 45s before end
    private func checkMarkers(at time: TimeInterval) {
        // Don't check while scrubbing or if post-video already showing
        guard !isScrubbing, postVideoState == .hidden else { return }

        // Check intro marker (show 5 seconds early)
        if let intro = metadata.introMarker {
            // Skip malformed markers where end time is not after start time
            guard intro.endTimeSeconds > intro.startTimeSeconds else {
                // Invalid marker data - skip this check
                return
            }

            let previewStart = max(0, intro.startTimeSeconds - markerPreviewTime)

            // Reset skip flag if user rewound before the marker preview window.
            // Special case: when intro starts at 0 (previewStart is also 0), we reset if:
            // 1. User is at the very beginning (within 1 second of start), AND
            // 2. We've already left the marker region (activeMarker is nil)
            // This allows re-triggering after seeking back without causing repeated skips
            // during initial playback.
            if hasSkippedIntro {
                if time < previewStart {
                    hasSkippedIntro = false
                } else if previewStart == 0 && time < intro.startTimeSeconds + 1.0 && activeMarker == nil {
                    hasSkippedIntro = false
                }
            }

            if time >= previewStart && time < intro.endTimeSeconds {
                handleMarkerActive(intro, isIntro: true, currentTime: time)
                return
            }
        }

        // Check credits marker - trigger post-video when credits START
        // But only if credits are in a sensible position (last 50% of video or < 5 min remaining)
        if let credits = metadata.creditsMarker {
            let previewStart = max(0, credits.startTimeSeconds - markerPreviewTime)
            let creditsStartPercent = duration > 0 ? credits.startTimeSeconds / duration : 1.0
            let remainingAfterCredits = duration - credits.startTimeSeconds

            // Sanity check: credits should be in the last half of the video OR < 5 min of content remains
            let creditsAreValid = creditsStartPercent >= 0.5 || remainingAfterCredits < 300

            // Reset flags if user rewound before the marker
            if time < previewStart {
                if hasSkippedCredits { hasSkippedCredits = false }
                if hasTriggeredPostVideo { hasTriggeredPostVideo = false }
            }

            // Trigger post-video summary when credits start (not when skip button would show)
            // Only if the credits marker is in a valid position
            if time >= credits.startTimeSeconds && !hasTriggeredPostVideo && creditsAreValid {
                hasTriggeredPostVideo = true
                print("🎬 [PostVideo] Credits marker started at \(credits.startTimeSeconds)s, triggering summary")
                Task { await handlePlaybackEnded() }
                return
            }

            // Show skip button 5 seconds early (before credits actually start)
            // Only show if credits marker is in a valid position
            if creditsAreValid && time >= previewStart && time < credits.startTimeSeconds {
                handleMarkerActive(credits, isIntro: false, currentTime: time)
                return
            }
        }

        // Check commercial markers
        for commercial in metadata.commercialMarkers {
            guard let commercialId = commercial.id else { continue }

            // Skip malformed markers
            guard commercial.endTimeSeconds > commercial.startTimeSeconds else { continue }

            let previewStart = max(0, commercial.startTimeSeconds - markerPreviewTime)

            // Reset skip flag if user rewound before the marker
            // Same special case handling for commercials starting at 0 as intro markers
            if skippedCommercialIds.contains(commercialId) {
                if time < previewStart {
                    skippedCommercialIds.remove(commercialId)
                } else if previewStart == 0 && time < commercial.startTimeSeconds + 1.0 && activeMarker == nil {
                    skippedCommercialIds.remove(commercialId)
                }
            }

            if time >= previewStart && time < commercial.endTimeSeconds {
                handleCommercialMarkerActive(commercial, currentTime: time)
                return
            }
        }

        // No credits marker - trigger post-video 45 seconds before end
        // BUT require at least 85% completion to avoid triggering too early on short videos
        if metadata.creditsMarker == nil && duration > 60 {
            let triggerTime = duration - 45
            let minCompletionTime = duration * 0.85  // At least 85% watched

            // Reset flag if user rewound before trigger point
            if time < triggerTime - 10 && hasTriggeredPostVideo {
                hasTriggeredPostVideo = false
            }

            // Only trigger if we're both near the end AND have watched most of the content
            if time >= triggerTime && time >= minCompletionTime && !hasTriggeredPostVideo {
                hasTriggeredPostVideo = true
                print("🎬 [PostVideo] 45s before end (no credits marker), triggering summary at \(time)s (duration: \(duration)s)")
                Task { await handlePlaybackEnded() }
                return
            }
        }

        // No active marker
        if activeMarker != nil {
            activeMarker = nil
            showSkipButton = false
        }
    }

    /// Handle when playback enters a marker range (or preview window)
    /// Auto-skip only triggers when actually inside the marker (at or past startTimeSeconds),
    /// not during the 5-second preview window before the marker starts.
    private func handleMarkerActive(_ marker: PlexMarker, isIntro: Bool, currentTime: TimeInterval) {
        let autoSkipIntro = UserDefaults.standard.bool(forKey: "autoSkipIntro")
        let autoSkipCredits = UserDefaults.standard.bool(forKey: "autoSkipCredits")
        let showSkipButtonSetting = UserDefaults.standard.object(forKey: "showSkipButton") as? Bool ?? true

        // Only auto-skip when actually inside the marker (not during preview window)
        // This ensures we use Plex's exact marker timing and don't cut off content
        let insideMarker = currentTime >= marker.startTimeSeconds

        // Check for auto-skip (only when inside actual marker range)
        if isIntro && autoSkipIntro && !hasSkippedIntro && insideMarker {
            hasSkippedIntro = true
            Task { await skipMarker(marker) }
            return
        }

        if !isIntro && autoSkipCredits && !hasSkippedCredits && insideMarker {
            hasSkippedCredits = true
            Task { await skipMarker(marker) }
            return
        }

        // Show skip button if enabled and not already skipped
        if showSkipButtonSetting {
            let alreadySkipped = isIntro ? hasSkippedIntro : hasSkippedCredits
            if !alreadySkipped && activeMarker == nil {
                // Only log and set when first entering the marker range
                activeMarker = marker
                showSkipButton = true
                let markerType = isIntro ? "intro" : "credits"
                print("⏭️ [Skip] Showing skip button for \(markerType) marker: \(marker.startTimeSeconds)s - \(marker.endTimeSeconds)s")
            }
        }
    }

    /// Handle when playback enters a commercial marker range (or preview window)
    /// Auto-skip only triggers when actually inside the marker (at or past startTimeSeconds).
    private func handleCommercialMarkerActive(_ marker: PlexMarker, currentTime: TimeInterval) {
        guard let commercialId = marker.id else { return }

        let autoSkipAds = UserDefaults.standard.bool(forKey: "autoSkipAds")
        let showSkipButtonSetting = UserDefaults.standard.object(forKey: "showSkipButton") as? Bool ?? true

        // Only auto-skip when actually inside the marker (not during preview window)
        let insideMarker = currentTime >= marker.startTimeSeconds

        // Check for auto-skip (only when inside actual marker range)
        if autoSkipAds && !skippedCommercialIds.contains(commercialId) && insideMarker {
            skippedCommercialIds.insert(commercialId)
            Task { await skipMarker(marker) }
            return
        }

        // Show skip button if enabled and not already skipped
        if showSkipButtonSetting {
            if !skippedCommercialIds.contains(commercialId) && activeMarker == nil {
                activeMarker = marker
                showSkipButton = true
                print("⏭️ [Skip] Showing skip button for commercial marker: \(marker.startTimeSeconds)s - \(marker.endTimeSeconds)s")
            }
        }
    }

    /// Skip to end of current marker (called from UI skip button)
    func skipActiveMarker() async {
        guard let marker = activeMarker else { return }
        await skipMarker(marker)
    }

    /// Skip to end of a specific marker
    private func skipMarker(_ marker: PlexMarker) async {
        // Mark as skipped to prevent re-showing button if user seeks back
        if marker.isIntro {
            hasSkippedIntro = true
        } else if marker.isCredits {
            hasSkippedCredits = true
        } else if marker.isCommercial, let commercialId = marker.id {
            skippedCommercialIds.insert(commercialId)
        }

        // Seek to end of marker
        await seek(to: marker.endTimeSeconds)

        // Hide button
        activeMarker = nil
        showSkipButton = false
    }

    /// Label for current skip button
    var skipButtonLabel: String {
        guard let marker = activeMarker else { return "Skip" }
        if marker.isIntro {
            return "Skip Intro"
        } else if marker.isCredits {
            return "Skip Credits"
        } else if marker.isCommercial {
            return "Skip Ad"
        }
        return "Skip"
    }

    /// Fetch detailed metadata with markers if not already present
    private func fetchMarkersIfNeeded() async {
        guard let ratingKey = metadata.ratingKey else {
            print("⏭️ [Skip] No rating key for metadata fetch")
            return
        }

        do {
            let networkManager = PlexNetworkManager.shared
            let detailedMetadata = try await networkManager.getFullMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )

            // Update metadata with markers from detailed fetch
            if let markers = detailedMetadata.Marker, !markers.isEmpty {
                metadata.Marker = markers
                print("⏭️ [Skip] Fetched \(markers.count) markers from detailed metadata")
            } else {
                print("⏭️ [Skip] Detailed metadata also has no markers")
            }
        } catch {
            print("⏭️ [Skip] Failed to fetch detailed metadata: \(error)")
        }
    }

    // MARK: - Post-Video Handling

    /// Handle video end - transition to post-video summary
    func handlePlaybackEnded() async {
        // Don't re-enter if already showing post-video
        guard postVideoState == .hidden else { return }

        // Mark as watched immediately when playback ends/reaches credits
        await markCurrentAsWatched()

        print("🎬 [PostVideo] Playback ended, preparing summary...")
        print("🎬 [PostVideo] Content type: \(metadata.type ?? "nil")")
        print("🎬 [PostVideo] Title: \(metadata.title ?? "nil")")
        print("🎬 [PostVideo] parentRatingKey (season): \(metadata.parentRatingKey ?? "nil")")
        print("🎬 [PostVideo] grandparentRatingKey (show): \(metadata.grandparentRatingKey ?? "nil")")
        print("🎬 [PostVideo] Current episode index: \(metadata.index ?? -1)")

        postVideoState = .loading

        let isEpisode = metadata.type == "episode"

        if isEpisode {
            // If parent metadata is missing (e.g., from Continue Watching), fetch full metadata first
            if metadata.parentRatingKey == nil || metadata.index == nil {
                print("🎬 [PostVideo] Missing parent metadata, fetching full metadata...")
                await fetchFullMetadataIfNeeded()
                print("🎬 [PostVideo] After fetch - parentRatingKey: \(metadata.parentRatingKey ?? "nil"), index: \(metadata.index ?? -1)")
            }

            // Fetch next episode
            nextEpisode = await fetchNextEpisode()
            print("🎬 [PostVideo] Next episode result: \(nextEpisode?.title ?? "nil")")

            // Animate video shrink
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                videoFrameState = .shrunk
            }
            print("🎬 [PostVideo] Video frame set to shrunk")

            // Show episode summary after brief delay
            try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2s
            postVideoState = .showingEpisodeSummary
            print("🎬 [PostVideo] State set to showingEpisodeSummary")

            // Start countdown and preload if next episode exists
            if nextEpisode != nil {
                print("🎬 [PostVideo] Starting autoplay countdown")
                startAutoplayCountdown()
                // Preload next episode in background for instant playback
                Task {
                    await preloadNextEpisode()
                }
            } else {
                print("🎬 [PostVideo] No next episode, skipping countdown")
            }
        } else {
            // Movie - fetch recommendations
            recommendations = await fetchRecommendations()

            // Animate video shrink
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                videoFrameState = .shrunk
            }

            // Show movie summary after brief delay
            try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2s
            postVideoState = .showingMovieSummary
        }
    }

    /// Fetch full metadata if parent keys are missing (e.g., from Continue Watching)
    private func fetchFullMetadataIfNeeded() async {
        guard let ratingKey = metadata.ratingKey else {
            print("🎬 [PostVideo] No rating key for full metadata fetch")
            return
        }

        let networkManager = PlexNetworkManager.shared

        do {
            let fullMetadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )

            // Update our metadata with the parent keys
            if metadata.parentRatingKey == nil {
                metadata.parentRatingKey = fullMetadata.parentRatingKey
            }
            if metadata.grandparentRatingKey == nil {
                metadata.grandparentRatingKey = fullMetadata.grandparentRatingKey
            }
            if metadata.parentIndex == nil {
                metadata.parentIndex = fullMetadata.parentIndex
            }
            if metadata.grandparentTitle == nil {
                metadata.grandparentTitle = fullMetadata.grandparentTitle
            }
            if metadata.index == nil {
                metadata.index = fullMetadata.index
            }

            print("🎬 [PostVideo] Updated metadata from full fetch:")
            print("🎬 [PostVideo]   parentRatingKey: \(metadata.parentRatingKey ?? "nil")")
            print("🎬 [PostVideo]   grandparentRatingKey: \(metadata.grandparentRatingKey ?? "nil")")
            print("🎬 [PostVideo]   parentIndex (season): \(metadata.parentIndex ?? -1)")
            print("🎬 [PostVideo]   index (episode): \(metadata.index ?? -1)")
        } catch {
            print("🎬 [PostVideo] Failed to fetch full metadata: \(error)")
        }
    }

    /// Fetch the next episode for TV shows
    func fetchNextEpisode() async -> PlexMetadata? {
        print("🎬 [PostVideo] fetchNextEpisode called")
        print("🎬 [PostVideo] seasonKey (parentRatingKey): \(metadata.parentRatingKey ?? "nil")")
        print("🎬 [PostVideo] currentIndex: \(metadata.index ?? -1)")

        // Check if next episode was prefetched
        if let ratingKey = metadata.ratingKey,
           let cached = await PlexDataStore.shared.getCachedNextEpisode(for: ratingKey) {
            print("🎬 [PostVideo] Using prefetched next episode: \(cached.episodeString ?? "?") - \(cached.title ?? "?")")
            return cached
        }

        guard let seasonKey = metadata.parentRatingKey,
              let currentIndex = metadata.index else {
            print("🎬 [PostVideo] FAILED: No season key or episode index")
            return nil
        }

        let networkManager = PlexNetworkManager.shared

        do {
            // Get all episodes in current season
            print("🎬 [PostVideo] Fetching episodes for season: \(seasonKey)")
            let episodes = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: seasonKey
            )
            print("🎬 [PostVideo] Got \(episodes.count) episodes in season")

            // Sort episodes by index and find the next one after current
            let sortedEpisodes = episodes
                .filter { $0.index != nil }
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            // Find episodes with index greater than current, take the first one
            if let nextEp = sortedEpisodes.first(where: { ($0.index ?? 0) > currentIndex }) {
                print("🎬 [PostVideo] Found next episode: S\(nextEp.parentIndex ?? 0)E\(nextEp.index ?? 0) - \(nextEp.title ?? "?")")
                return nextEp
            }

            // Debug: show what episodes and indexes we have
            let episodeInfo = sortedEpisodes.map { "E\($0.index ?? -1): \($0.title ?? "?")" }
            print("🎬 [PostVideo] No episode after index \(currentIndex) found. Episodes in season: \(episodeInfo). Trying next season...")

            // End of season - try next season
            guard let showKey = metadata.grandparentRatingKey,
                  let seasonIndex = metadata.parentIndex else {
                print("🎬 [PostVideo] End of season, no show key for next season lookup")
                return nil
            }

            let seasons = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: showKey
            )

            // Sort seasons by index and find the next one after current
            let sortedSeasons = seasons
                .filter { $0.index != nil }
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            guard let nextSeason = sortedSeasons.first(where: { ($0.index ?? 0) > seasonIndex }),
                  let nextSeasonKey = nextSeason.ratingKey else {
                let seasonIndexes = sortedSeasons.compactMap { $0.index }
                print("🎬 [PostVideo] End of series - no season after \(seasonIndex). Available seasons: \(seasonIndexes)")
                return nil
            }

            let nextSeasonEpisodes = try await networkManager.getChildren(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: nextSeasonKey
            )

            // Get first episode of next season (sorted by index)
            let sortedNextSeasonEps = nextSeasonEpisodes
                .filter { $0.index != nil }
                .sorted { ($0.index ?? 0) < ($1.index ?? 0) }

            if let firstEp = sortedNextSeasonEps.first {
                print("🎬 [PostVideo] Found first episode of next season: S\(firstEp.parentIndex ?? 0)E\(firstEp.index ?? 0)")
                return firstEp
            }

            return nil
        } catch {
            print("🎬 [PostVideo] Failed to fetch next episode: \(error)")
            return nil
        }
    }

    /// Fetch recommendations for movies
    func fetchRecommendations() async -> [PlexMetadata] {
        guard let ratingKey = metadata.ratingKey else { return [] }

        let networkManager = PlexNetworkManager.shared

        do {
            let related = try await networkManager.getRelatedItems(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey,
                limit: 10
            )
            print("🎬 [PostVideo] Fetched \(related.count) recommendations")
            return related
        } catch {
            print("🎬 [PostVideo] Failed to fetch recommendations: \(error)")
            return []
        }
    }

    /// Start autoplay countdown timer
    func startAutoplayCountdown() {
        // Default to 5 seconds if not set (key doesn't exist)
        // 0 explicitly means disabled
        let countdownSetting: Int
        if UserDefaults.standard.object(forKey: "autoplayCountdown") == nil {
            countdownSetting = 5  // Default: 5 seconds
        } else {
            countdownSetting = UserDefaults.standard.integer(forKey: "autoplayCountdown")
        }

        // 0 means disabled
        guard countdownSetting > 0 else {
            print("🎬 [PostVideo] Autoplay countdown disabled")
            return
        }

        countdownSeconds = countdownSetting
        isCountdownPaused = false

        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard !self.isCountdownPaused else { return }

                self.countdownSeconds -= 1

                if self.countdownSeconds <= 0 {
                    self.countdownTimer?.invalidate()
                    await self.playNextEpisode()
                }
            }
        }
    }

    /// Preload the next episode's stream URL and metadata for instant playback
    private func preloadNextEpisode() async {
        guard let next = nextEpisode, let ratingKey = next.ratingKey else { return }

        print("🎬 [Preload] Starting preload for: \(next.title ?? "Unknown")")

        let networkManager = PlexNetworkManager.shared

        // Fetch full metadata with markers
        do {
            let fullMetadata = try await networkManager.getFullMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )
            preloadedNextMetadata = fullMetadata
            print("🎬 [Preload] Fetched metadata with \(fullMetadata.Marker?.count ?? 0) markers")
        } catch {
            print("🎬 [Preload] Failed to fetch metadata: \(error)")
            preloadedNextMetadata = next
        }

        // Build stream URL for next episode
        let metadata = preloadedNextMetadata ?? next
        if let partKey = metadata.Media?.first?.Part?.first?.key {
            preloadedNextStreamURL = networkManager.buildVLCDirectPlayURL(
                serverURL: serverURL,
                authToken: authToken,
                partKey: partKey
            )
            preloadedNextStreamHeaders = [
                "X-Plex-Token": authToken,
                "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
                "X-Plex-Platform": PlexAPI.platform,
                "X-Plex-Device": PlexAPI.deviceName,
                "X-Plex-Product": PlexAPI.productName
            ]
            print("🎬 [Preload] Stream URL ready: \(preloadedNextStreamURL?.absoluteString ?? "nil")")
        }
    }

    /// Clear preloaded data
    private func clearPreloadedData() {
        preloadedNextStreamURL = nil
        preloadedNextStreamHeaders = [:]
        preloadedNextMetadata = nil
    }

    /// Cancel countdown but stay on summary
    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isCountdownPaused = true
        print("🎬 [PostVideo] Countdown cancelled")
    }

    /// Play the next episode
    func playNextEpisode() async {
        guard let next = nextEpisode else { return }

        // Mark current episode as watched BEFORE switching to next
        await markCurrentAsWatched()

        print("🎬 [PostVideo] Playing next episode: \(next.title ?? "Unknown")")

        // Stop countdown and reset all countdown state
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownSeconds = 0
        isCountdownPaused = false

        // Reset post-video state with animation to return video to fullscreen
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            postVideoState = .hidden
            videoFrameState = .fullscreen
        }
        print("🎬 [PostVideo] Reset state: postVideoState=\(postVideoState), videoFrameState=\(videoFrameState)")

        // Use preloaded metadata if available (has markers), otherwise use fetched next episode
        metadata = preloadedNextMetadata ?? next

        // Reset start offset so next episode starts from beginning (not resume position)
        startOffset = nil

        // Reset skip tracking for new episode
        hasSkippedIntro = false
        hasSkippedCredits = false
        skippedCommercialIds.removeAll()
        hasTriggeredPostVideo = false
        nextEpisode = nil

        // Ensure next episode has required metadata for subsequent next-up detection
        if metadata.parentRatingKey == nil || metadata.index == nil {
            print("🎬 [PostVideo] Next episode missing parent metadata, fetching full details...")
            await fetchFullMetadataIfNeeded()
        }

        // Use preloaded stream URL if available, otherwise prepare fresh
        if let preloadedURL = preloadedNextStreamURL {
            print("🎬 [PostVideo] Using preloaded stream URL")
            streamURL = preloadedURL
            streamHeaders = preloadedNextStreamHeaders
        } else {
            print("🎬 [PostVideo] No preloaded URL, preparing fresh...")
            await prepareStreamURL()
        }

        // Clear preloaded data
        clearPreloadedData()

        // Start playback
        await startPlayback()
    }

    /// Dismiss post-video overlay and return to fullscreen video
    /// Note: Does NOT reset hasTriggeredPostVideo - that prevents re-triggering while still in the credits.
    /// The flag is only reset when seeking backwards past the trigger point or starting new content.
    func dismissPostVideo() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        postVideoState = .hidden
        videoFrameState = .fullscreen
        nextEpisode = nil
        recommendations = []
        countdownSeconds = 0
        isCountdownPaused = false
        // Don't reset hasTriggeredPostVideo here - prevents immediate re-trigger
        clearPreloadedData()
    }

    // MARK: - Navigation

    /// Navigate to the current episode's season
    func navigateToSeason() {
        guard let seasonKey = metadata.parentRatingKey else { return }
        stopPlayback()
        dismissPostVideo()
        NotificationCenter.default.post(
            name: .navigateToContent,
            object: nil,
            userInfo: ["ratingKey": seasonKey, "type": "season"]
        )
    }

    /// Navigate to the current episode's show
    func navigateToShow() {
        guard let showKey = metadata.grandparentRatingKey else { return }
        stopPlayback()
        dismissPostVideo()
        NotificationCenter.default.post(
            name: .navigateToContent,
            object: nil,
            userInfo: ["ratingKey": showKey, "type": "show"]
        )
    }

    // MARK: - Progress Tracking

    /// Mark current content as watched (for use before transitioning to next episode)
    private func markCurrentAsWatched() async {
        guard let ratingKey = metadata.ratingKey, !ratingKey.isEmpty else { return }

        // Report stopped state
        await PlexProgressReporter.shared.reportProgress(
            ratingKey: ratingKey,
            time: currentTime,
            duration: duration,
            state: "stopped"
        )

        // Mark as watched (episode reached post-video, so it's effectively complete)
        await PlexProgressReporter.shared.markAsWatched(ratingKey: ratingKey)
        print("📊 [Progress] Marked \(ratingKey) as watched")
    }

    // MARK: - Cleanup

    deinit {
        controlsTimer?.invalidate()
        scrubTimer?.invalidate()
        countdownTimer?.invalidate()
        seekIndicatorTimer?.invalidate()
        if let observer = appBackgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appBecameActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Ensure screensaver is re-enabled when player is deallocated
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - Navigation Notifications

extension Notification.Name {
    /// Posted when player requests navigation to a specific content item
    /// userInfo contains: "ratingKey" (String), "type" (String: "show", "season", "movie")
    static let navigateToContent = Notification.Name("navigateToContent")

    /// Posted when Plex data needs to be refreshed (e.g., after playback ends)
    /// Views showing Plex content should refresh their data when receiving this
    static let plexDataNeedsRefresh = Notification.Name("plexDataNeedsRefresh")
}
