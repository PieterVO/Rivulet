//
//  AetherPlayer.swift
//  Rivulet
//
//  PlayerProtocol-conforming adapter around AetherEngine.
//
//  Rivulet's only player: VOD and Live TV (one instance per grid slot).
//  Video must be displayed through `bind(view:)` / AetherVideoSurfaceView —
//  the engine attaches the active backend's layer itself (AVPlayerLayer on
//  the native path, AVSampleBufferDisplayLayer on the software path).
//  `currentAVPlayer` is still republished for non-render uses (mute
//  reapplication, item-level metadata observation).
//
//  Aether handles HDR10+ dynamic metadata preservation, HLG signaling,
//  EAC3+JOC Atmos stream-copy through MKV, and DV P5/P8.1 via dvh1+dvcC
//  in HLS-fMP4 sample entries. DV P7 plays as HDR10 base only. Routing
//  decisions live in ContentRouter; this adapter just bridges the engine
//  surface.
//

import AVFoundation
import Combine
import Foundation
import UIKit
import AetherEngine

@MainActor
final class AetherPlayer: PlayerProtocol {

    private let engine: AetherEngine

    private let stateSubject = CurrentValueSubject<UniversalPlaybackState, Never>(.idle)
    private let timeSubject = PassthroughSubject<TimeInterval, Never>()
    private let errorSubject = PassthroughSubject<PlayerError, Never>()
    private var cancellables = Set<AnyCancellable>()

    /// Re-publishes AetherEngine.currentAVPlayer so the host player view can
    /// rebind its .player on every internal Aether reload (audio-track
    /// switch / background reopen). Documented at AetherEngine.swift:1225.
    @Published private(set) var currentAVPlayer: AVPlayer?

    /// Mute state for the underlying AVPlayer. Tracked so it survives Aether's
    /// internal player swaps (see the `$currentAVPlayer` sink). Used by the
    /// Live TV grid, where non-focused slots play muted.
    private(set) var isMuted = false

    /// Subtitle cues bridged from AetherEngine.SubtitleCue into Rivulet's
    /// nameable AetherSubtitleCue (carries text AND bitmap bodies). Converted
    /// on the main queue in wireUpPublishers so the host overlay binds directly.
    @Published private(set) var subtitleCues: [AetherSubtitleCue] = []

    /// Mirrors engine.$isSubtitleActive. True when any subtitle track
    /// (embedded or sidecar) is selected and the engine has cue data.
    @Published private(set) var isSubtitleActive: Bool = false

    /// Mirrors engine.$isBuffering. Aether keeps its playback state as
    /// `.playing` during AVPlayer waits to avoid transport flicker, so Rivulet
    /// observes this separately for spinner/stall handling.
    @Published private(set) var isBuffering: Bool = false

    /// Active Aether subtitle stream index, or nil when subtitles are off.
    @Published private(set) var activeSubtitleTrackId: Int?

    /// Active Aether audio stream index, or nil before the engine resolves one.
    @Published private(set) var activeAudioTrackId: Int?

    /// Source-timeline position in seconds, mirroring clock.$currentTime.
    /// Equal to currentTime on all current Aether paths (PlaybackClock
    /// unifies source-PTS and wall-clock onto a single value).
    @Published private(set) var sourceTime: Double = 0

    @Published private(set) var audioTracks: [MediaTrack] = []
    private var _subtitleTracks: [MediaTrack] = []

    init() {
        do {
            self.engine = try AetherEngine()
        } catch {
            fatalError("AetherEngine init failed: \(error)")
        }
        wireUpPublishers()
    }

    private func wireUpPublishers() {
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] aetherState in
                self?.stateSubject.send(Self.translate(aetherState))
            }
            .store(in: &cancellables)

        // AetherEngine 3.x moved the high-frequency clock off the engine's
        // own objectWillChange into a separate PlaybackClock (the engine
        // does NOT fire on clock ticks). Observe clock.$currentTime.
        // Also drive sourceTime here so subtitle lookups share the same tick.
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                self?.timeSubject.send(t)
                self?.sourceTime = t
            }
            .store(in: &cancellables)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                // Convert here: each cue's type is inferred as
                // AetherEngine.SubtitleCue (it cannot be named explicitly),
                // and the body cases are pattern-matched without naming them.
                self?.subtitleCues = cues.map { cue in
                    let body: AetherSubtitleCue.Body
                    switch cue.body {
                    case .text(let string):
                        body = .text(string)
                    case .image(let image):
                        body = .image(cgImage: image.cgImage, position: image.position)
                    }
                    return AetherSubtitleCue(
                        id: cue.id,
                        startTime: cue.startTime,
                        endTime: cue.endTime,
                        body: body
                    )
                }
            }
            .store(in: &cancellables)

        engine.$isSubtitleActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isSubtitleActive = active
            }
            .store(in: &cancellables)

        engine.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buffering in
                self?.isBuffering = buffering
            }
            .store(in: &cancellables)

        engine.$activeSubtitleTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                self?.activeSubtitleTrackId = id
            }
            .store(in: &cancellables)

        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                self?.activeAudioTrackId = id
            }
            .store(in: &cancellables)

        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avp in
                guard let self else { return }
                // Reapply mute across internal reloads — Aether swaps the
                // AVPlayer on audio-track switch / background reopen, and the
                // Live TV grid relies on per-slot muting persisting.
                avp?.isMuted = self.isMuted
                self.currentAVPlayer = avp
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.audioTracks = tracks.map(Self.translateTrack)
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?._subtitleTracks = tracks.map(Self.translateTrack)
            }
            .store(in: &cancellables)
    }

    private static func translate(_ s: PlaybackState) -> UniversalPlaybackState {
        switch s {
        case .idle: return .idle
        case .loading: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .seeking: return .buffering
        case .ended: return .ended
        case .error(let message): return .failed(.unknown(message))
        }
    }

    private static func translateTrack(_ t: TrackInfo) -> MediaTrack {
        // Build a human-readable name from whatever Aether provides.
        // FFmpeg stream names are often empty for audio; fall back through
        // localized language name → raw language tag → codec so the picker
        // always shows something meaningful.
        let name: String
        if !t.name.isEmpty {
            name = t.name
        } else if let lang = t.language, !lang.isEmpty {
            name = Locale.current.localizedString(forLanguageCode: lang) ?? lang
        } else {
            name = t.codec.uppercased()
        }
        return MediaTrack(
            id: t.id,
            name: name,
            language: t.language,
            languageCode: t.language,
            codec: t.codec,
            isDefault: t.isDefault,
            isHearingImpaired: t.isHearingImpaired,
            channels: t.channels > 0 ? t.channels : nil
        )
    }

    /// Read panel HDR state for LoadOptions.panelIsInHDRMode. Matches
    /// the post-handshake EDR detection pattern Aether 2.0 documents:
    /// `> 1.001` means the panel accepted HDR signaling.
    private static func panelIsInHDRMode() -> Bool {
        guard let screen = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.screen })
            .first
        else { return false }
        return screen.currentEDRHeadroom > 1.001
    }

    // MARK: - PlayerProtocol state

    var isPlaying: Bool { engine.state == .playing }
    var currentTime: TimeInterval { engine.currentTime }
    var duration: TimeInterval { engine.duration }

    /// Duration updates. The engine publishes `duration` once the source is
    /// probed; the VM needs this (not just `timePublisher`) so Plex progress
    /// reports carry a real duration (viewOffset + watched threshold).
    var durationPublisher: AnyPublisher<TimeInterval, Never> {
        engine.$duration.eraseToAnyPublisher()
    }
    var bufferedTime: TimeInterval { engine.bufferedPosition }
    var playbackRate: Float {
        get { _playbackRate }
        set {
            _playbackRate = newValue
            engine.setRate(newValue)
        }
    }
    private var _playbackRate: Float = 1.0

    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    var timePublisher: AnyPublisher<TimeInterval, Never> {
        timeSubject.eraseToAnyPublisher()
    }
    var errorPublisher: AnyPublisher<PlayerError, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    // MARK: - Controls

    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?) async throws {
        try await load(
            url: url,
            headers: headers,
            startTime: startTime,
            subtitleLanguageHintsByStreamIndex: [:]
        )
    }

    /// Live variant (separate from the PlayerProtocol requirement — a
    /// defaulted extra parameter would break conformance).
    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?, isLive: Bool) async throws {
        try await load(
            url: url,
            headers: headers,
            startTime: startTime,
            subtitleLanguageHintsByStreamIndex: [:],
            isLive: isLive
        )
    }

    func load(
        url: URL,
        headers: [String: String]?,
        startTime: TimeInterval?,
        subtitleLanguageHintsByStreamIndex: [Int: String],
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        isLive: Bool = false
    ) async throws {
        // .lossless: FLAC encode for non-stream-copy audio (TrueHD, DTS,
        // DTS-HD MA, MP3, Opus). FLAC encode is ~3x realtime on A15 vs
        // EAC3's ~0.5x realtime, so segment production keeps up with
        // AVPlayer's HLS pipeline on high-bitrate 4K content.
        //
        // Tradeoff: needs a sink that accepts multichannel LPCM over
        // HDMI (Denon / Marantz / NAD AVRs). On AirPlay-to-HomePod or
        // stereo-LPCM-only routes the multichannel LPCM downmixes to
        // stereo, but the encode-throughput win is still worth it.
        //
        // subtitleLanguageHintsByStreamIndex is accepted for call-site
        // compatibility but unused: upstream 4.8.0 has no per-stream
        // language-hint parameter. preferredSubtitleLanguages (below)
        // is the supported replacement for steering initial subtitle
        // selection.
        // isLive: engine auto-detection is deliberately disabled upstream
        // (VOD MKVs with broken duration headers are too common), so the
        // host must declare live sources. Enables the engine's live path:
        // clock live-edge tracking, LiveReloadPolicy reconnect, and
        // seek(to:) becoming a no-op.
        let options = LoadOptions(
            suppressDisplayCriteria: false,
            httpHeaders: headers ?? [:],
            matchContentEnabled: true,
            panelIsInHDRMode: Self.panelIsInHDRMode(),
            audioBridgeMode: .lossless,
            isLive: isLive,
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages
        )
        do {
            try await engine.load(url: url, startPosition: startTime, options: options)
        } catch {
            let pe = PlayerError.loadFailed(String(describing: error))
            errorSubject.send(pe)
            throw pe
        }
    }

    /// Hand external metadata (title, artwork, description, genre) to the
    /// engine so AVPlayerViewController's info panel and the system Now
    /// Playing surface populate. Aether stashes these and applies them onto
    /// its internally created AVPlayerItem, replaying across internal reloads
    /// (audio-track switch, background reopen). Call BEFORE load(url:).
    ///
    /// Chapters are NOT covered: AetherEngine 3.3.0 has no navigation-marker
    /// API, so `navigationMarkerGroups` can't be injected here.
    func setExternalMetadata(_ items: [AVMetadataItem]) {
        engine.setExternalMetadata(items)
    }

    func play() { engine.play() }
    func pause() { engine.pause() }
    func stop() { engine.stop() }

    // MARK: - Render surface

    /// Attach the engine's render surface. The engine hosts whichever
    /// CALayer the active backend uses and re-attaches it across internal
    /// session swaps; binding a different view detaches the old one.
    func bind(view: AetherPlayerView) {
        engine.bind(view: view)
    }

    /// Detach a previously bound render surface. Idempotent.
    func unbind(view: AetherPlayerView) {
        engine.unbind(view: view)
    }

    /// Mute/unmute the underlying AVPlayer. Persisted in `isMuted` so it's
    /// reapplied when Aether swaps its player across internal reloads.
    func setMuted(_ muted: Bool) {
        isMuted = muted
        // engine.volume covers both backends (the software path has no
        // AVPlayer) and is remembered across internal host swaps.
        // currentAVPlayer.isMuted stays as well: it mutes the native path
        // even mid-swap, before the engine re-applies desired volume.
        engine.volume = muted ? 0 : 1
        currentAVPlayer?.isMuted = muted
    }
    func seek(to time: TimeInterval) async { await engine.seek(to: time) }

    // MARK: - Tracks

    var subtitleTracks: [MediaTrack] { _subtitleTracks }
    var currentAudioTrackId: Int? { activeAudioTrackId }
    var currentSubtitleTrackId: Int? { activeSubtitleTrackId }

    func selectAudioTrack(id: Int) {
        engine.selectAudioTrack(index: id)
    }

    func selectSubtitleTrack(id: Int?) {
        if let id {
            engine.selectSubtitleTrack(index: id)
        } else {
            engine.clearSubtitle()
        }
    }

    /// Load a sidecar subtitle file (SRT, ASS, VTT, PGS) by URL.
    /// `headers` is forwarded as `httpHeaders` to AetherEngine for
    /// authenticated subtitle URLs (Plex token, CDN auth, etc.).
    func selectSidecarSubtitle(url: URL, headers: [String: String]?) {
        engine.selectSidecarSubtitle(url: url, httpHeaders: headers)
    }

    func prepareForReuse() {
        // No-op: AetherEngine doesn't have a reset-without-stop primitive.
        // stop() is called when the view model swaps players, and a fresh
        // AetherPlayer() instance is created for the next session.
    }
}
