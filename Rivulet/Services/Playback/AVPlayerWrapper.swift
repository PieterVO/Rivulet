//
//  AVPlayerWrapper.swift
//  Rivulet
//
//  AVPlayer-based video player for Dolby Vision VOD content
//  Used when "Use AVPlayer for Dolby Vision" setting is enabled
//

import Foundation
import AVFoundation
import CoreMedia
import Combine
import Sentry

@MainActor
final class AVPlayerWrapper: NSObject, ObservableObject {

    // MARK: - AVPlayer Components

    @Published private(set) var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    // Keep a non-isolated reference for cleanup in deinit
    private nonisolated(unsafe) var _playerForCleanup: AVPlayer?

    // MARK: - State

    private let playbackStateSubject = CurrentValueSubject<UniversalPlaybackState, Never>(.idle)
    private let timeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private let errorSubject = PassthroughSubject<PlayerError, Never>()

    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var errorObservationCancellable = Set<AnyCancellable>()

    private var _duration: TimeInterval = 0
    private var _isMuted: Bool = false
    private var loadingTimeoutTask: Task<Void, Never>?
    private var currentStreamURL: URL?

    // MARK: - Publishers

    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }

    var timePublisher: AnyPublisher<TimeInterval, Never> {
        timeSubject.eraseToAnyPublisher()
    }

    var errorPublisher: AnyPublisher<PlayerError, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    // MARK: - Playback State

    var isPlaying: Bool {
        player?.rate ?? 0 > 0
    }

    var currentTime: TimeInterval {
        player?.currentTime().seconds ?? 0
    }

    var duration: TimeInterval {
        _duration
    }

    var isMuted: Bool {
        _isMuted
    }

    // MARK: - Initialization

    override init() {
        super.init()
    }

    deinit {
        // Clean up time observer synchronously in deinit
        // Other observers will be cleaned up by ARC
        if let timeObserver = timeObserver, let player = _playerForCleanup {
            player.removeTimeObserver(timeObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Playback Controls

    /// Load a URL for playback
    /// - Parameters:
    ///   - url: The URL to load
    ///   - headers: Optional HTTP headers for the request
    ///   - isLive: Whether this is a live stream (affects buffering behavior)
    func load(url: URL, headers: [String: String]?, isLive: Bool = false) async throws {
        print("🎬 AVPlayerWrapper: Loading URL: \(url) (isLive: \(isLive))")
        playbackStateSubject.send(.loading)
        currentStreamURL = url

        // Clean up previous player
        cleanupObservers()
        player?.pause()

        // Create asset with headers if needed
        var options: [String: Any] = [:]

        // For VOD content, use precise duration/timing for accurate seeking
        // For live streams, disable to avoid byte-range requests
        options[AVURLAssetPreferPreciseDurationAndTimingKey] = !isLive

        if let headers = headers, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }

        let asset = AVURLAsset(url: url, options: options)

        // Create player item
        if isLive {
            // Live streams: don't preload keys that require byte-range requests
            playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: [])
            playerItem?.preferredForwardBufferDuration = 4  // Buffer ahead for live
            playerItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        } else {
            // VOD: preload duration for accurate seeking
            playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["duration"])
            playerItem?.preferredForwardBufferDuration = 0  // Let system decide
            playerItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        }

        // Create or reuse player
        if player == nil {
            let newPlayer = AVPlayer(playerItem: playerItem)
            // For live streams, don't wait - just start playing
            // For VOD, let it buffer appropriately to minimize stalling
            newPlayer.automaticallyWaitsToMinimizeStalling = !isLive
            player = newPlayer
            _playerForCleanup = newPlayer
        } else {
            player?.automaticallyWaitsToMinimizeStalling = !isLive
            player?.replaceCurrentItem(with: playerItem)
        }

        // Apply mute state
        player?.isMuted = _isMuted

        // Setup observers
        setupObservers()

        if isLive {
            print("🎬 AVPlayerWrapper: Starting live playback")
            // Start playback immediately for live streams
            player?.play()
        } else {
            print("🎬 AVPlayerWrapper: VOD content loaded, ready to play")
            // For VOD, don't auto-play - let caller control
        }

        // Start loading timeout - if we don't get playback within 10 seconds, fail
        startLoadingTimeout()
    }

    private func startLoadingTimeout() {
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }

            // Check if we're still loading after timeout
            if case .loading = self.playbackStateSubject.value {
                print("🎬 AVPlayerWrapper: Loading timeout - stream may be incompatible")

                // Check error log for any clues
                if let errorLog = self.playerItem?.errorLog(),
                   let lastEvent = errorLog.events.last,
                   lastEvent.errorStatusCode != 0 {
                    print("🎬 AVPlayerWrapper: Found error in log: \(lastEvent.errorStatusCode)")

                    // Log to Sentry
                    let timeoutError = NSError(domain: "AVPlayerWrapper", code: lastEvent.errorStatusCode, userInfo: [
                        NSLocalizedDescriptionKey: "Loading timeout with error in log"
                    ])
                    self.logStreamFailureToSentry(
                        error: timeoutError,
                        errorCode: lastEvent.errorStatusCode,
                        errorDomain: lastEvent.errorDomain,
                        isCompatibilityError: true
                    )

                    let message = self.buildCompatibilityErrorMessage()
                    self.playbackStateSubject.send(.failed(.codecUnsupported(message)))
                    self.errorSubject.send(.codecUnsupported(message))
                } else {
                    // Log timeout without specific error
                    let timeoutError = NSError(domain: "AVPlayerWrapper", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Loading timeout - no playback started"
                    ])
                    self.logStreamFailureToSentry(
                        error: timeoutError,
                        errorCode: -1,
                        errorDomain: "AVPlayerWrapper",
                        isCompatibilityError: false
                    )

                    let message = "Stream failed to load. The format may be incompatible with AVPlayer."
                    self.playbackStateSubject.send(.failed(.loadFailed(message)))
                    self.errorSubject.send(.loadFailed(message))
                }
            }
        }
    }

    private func cancelLoadingTimeout() {
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = nil
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        cleanupObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        _playerForCleanup = nil
        playerItem = nil
        playbackStateSubject.send(.idle)
    }

    func seek(to time: TimeInterval) async {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        await player?.seek(to: cmTime)
        timeSubject.send(time)
    }

    // MARK: - Audio Control

    func setMuted(_ muted: Bool) {
        _isMuted = muted
        player?.isMuted = muted
    }

    // MARK: - Observers

    private func setupObservers() {
        guard let player = player, let playerItem = playerItem else { return }

        // Observe player rate (playing/paused)
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            let rate = player.rate
            let currentState = self.playbackStateSubject.value
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Don't change state if we're already in a terminal state (failed/ended)
                if case .failed = self.playbackStateSubject.value { return }
                if case .ended = self.playbackStateSubject.value { return }

                if rate > 0 {
                    // Playback started - cancel loading timeout
                    self.cancelLoadingTimeout()
                    self.playbackStateSubject.send(.playing)
                    print("🎬 AVPlayerWrapper: Playback started (rate: \(rate))")
                } else if currentState == .playing {
                    self.playbackStateSubject.send(.paused)
                }
            }
        }

        // Observe player item status
        itemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            let status = item.status
            let duration = item.duration.seconds
            let error = item.error
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    print("🎬 AVPlayerWrapper: Ready to play")
                    self._duration = duration.isFinite ? duration : 0
                    // Log track details for debugging (resolution/codec)
                    let videoTracks = item.asset.tracks(withMediaType: .video)
                    for (index, track) in videoTracks.enumerated() {
                        let formatDescriptions = track.formatDescriptions as? [CMFormatDescription] ?? []
                        let codecType = formatDescriptions.first.map { CMFormatDescriptionGetMediaSubType($0) }
                        let codecString = codecType.map { self.fourCCToString($0) } ?? "unknown"
                        let naturalSize = track.naturalSize
                        print("🎬 AVPlayerWrapper: Video track \(index) codec=\(codecString) size=\(Int(abs(naturalSize.width)))x\(Int(abs(naturalSize.height))) fps=\(track.nominalFrameRate)")
                    }
                    // Don't set playing here - let rate observation handle it
                case .failed:
                    self.cancelLoadingTimeout()
                    let message = error?.localizedDescription ?? "Unknown playback error"
                    print("🎬 AVPlayerWrapper: Playback failed - \(message)")

                    // Check if it's a format/compatibility issue
                    if let nsError = error as? NSError {
                        print("🎬 AVPlayerWrapper: Error domain: \(nsError.domain), code: \(nsError.code)")
                        // -12939 = byte-range not supported
                        // -11850 = operation interrupted
                        // -11819/-11821 = cannot decode
                        // Only treat specific codes as compatibility errors; generic CoreMedia errors are usually transient
                        let isCompatibilityError = nsError.code == -12939 || nsError.code == -11850 || nsError.code == -11819 || nsError.code == -11821

                        // Log to Sentry
                        self.logStreamFailureToSentry(
                            error: nsError,
                            errorCode: nsError.code,
                            errorDomain: nsError.domain,
                            isCompatibilityError: isCompatibilityError
                        )

                        if isCompatibilityError {
                            let compatMessage = self.buildCompatibilityErrorMessage()
                            self.playbackStateSubject.send(.failed(.codecUnsupported(compatMessage)))
                            self.errorSubject.send(.codecUnsupported(compatMessage))
                            return
                        }
                    }
                    self.playbackStateSubject.send(.failed(.unknown(message)))
                    self.errorSubject.send(.unknown(message))
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        // Also observe the player item's error property directly for immediate errors
        playerItem.publisher(for: \.error)
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                print("🎬 AVPlayerWrapper: Player item error observed - \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cancelLoadingTimeout()

                    // Handle error regardless of current state (error can occur after playback starts)
                    // Skip if already in failed state
                    if case .failed = self.playbackStateSubject.value { return }

                    let nsError = error as NSError
                    print("🎬 AVPlayerWrapper: Error details - domain: \(nsError.domain), code: \(nsError.code)")

                    // Non-fatal quirks: bandwidth variance, init segment variance, and remote XPC notices
                    if nsError.domain == "CoreMediaErrorDomain" &&
                        (nsError.code == -12318 || nsError.code == 1852797029 || nsError.code == -50) {
                        print("🎬 AVPlayerWrapper: Non-fatal CoreMedia warning (bandwidth/variant/init segment) - continuing playback")
                        return
                    }
                    if nsError.domain == "NSOSStatusErrorDomain" && nsError.code == -12860 {
                        print("🎬 AVPlayerWrapper: Non-fatal PlayerRemoteXPC warning - continuing playback")
                        return
                    }

                    // Check for compatibility/format errors
                    // Only treat specific known codes as compatibility issues
                    // -12939 = byte-range not supported
                    // -11850 = operation interrupted (often due to format issues)
                    // -11819/-11821 = cannot decode
                    let isCompatibilityError = nsError.code == -12939 || nsError.code == -11850 || nsError.code == -11819 || nsError.code == -11821

                    // Log to Sentry
                    self.logStreamFailureToSentry(
                        error: error,
                        errorCode: nsError.code,
                        errorDomain: nsError.domain,
                        isCompatibilityError: isCompatibilityError
                    )

                    if isCompatibilityError {
                        let message = self.buildCompatibilityErrorMessage()
                        print("🎬 AVPlayerWrapper: Setting state to FAILED (codec unsupported) - \(message)")
                        self.playbackStateSubject.send(.failed(.codecUnsupported(message)))
                        self.errorSubject.send(.codecUnsupported(message))
                    } else {
                        print("🎬 AVPlayerWrapper: Setting state to FAILED (unknown)")
                        self.playbackStateSubject.send(.failed(.unknown(error.localizedDescription)))
                        self.errorSubject.send(.unknown(error.localizedDescription))
                    }
                }
            }
            .store(in: &errorObservationCancellable)

        // Observe time updates
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                self?.timeSubject.send(seconds)
            }
        }

        // Observe buffering
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemPlaybackStalled),
            name: .AVPlayerItemPlaybackStalled,
            object: playerItem
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidPlayToEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemFailedToPlayToEnd),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem
        )

        // Observe error log entries (captures HTTP errors like -12939)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemNewErrorLogEntry),
            name: .AVPlayerItemNewErrorLogEntry,
            object: playerItem
        )

        // Observe access log for debugging
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemNewAccessLogEntry),
            name: .AVPlayerItemNewAccessLogEntry,
            object: playerItem
        )
    }

    private func cleanupObservers() {
        cancelLoadingTimeout()

        if let timeObserver = timeObserver, let player = player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        statusObservation?.invalidate()
        statusObservation = nil

        rateObservation?.invalidate()
        rateObservation = nil

        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        errorObservationCancellable.removeAll()

        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notifications

    @objc private func playerItemPlaybackStalled() {
        playbackStateSubject.send(.buffering)
    }

    @objc private func playerItemDidPlayToEnd() {
        playbackStateSubject.send(.ended)
    }

    @objc private func playerItemFailedToPlayToEnd(_ notification: Notification) {
        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            print("🎬 AVPlayerWrapper: Failed to play to end: \(error.localizedDescription)")
            let nsError = error as NSError

            // Ignore known non-fatal bandwidth/variant warnings so playback can continue
            if nsError.domain == "CoreMediaErrorDomain" &&
                (nsError.code == -12318 || nsError.code == 1852797029 || nsError.code == -50) {
                print("🎬 AVPlayerWrapper: Ignoring CoreMedia bandwidth/variant warning on end notification")
                return
            }
            if nsError.domain == "NSOSStatusErrorDomain" && nsError.code == -12860 {
                print("🎬 AVPlayerWrapper: Ignoring PlayerRemoteXPC warning on end notification")
                return
            }

            playbackStateSubject.send(.failed(.unknown(error.localizedDescription)))
            errorSubject.send(.unknown(error.localizedDescription))
        }
    }

    @objc private func playerItemNewErrorLogEntry(_ notification: Notification) {
        guard let playerItem = notification.object as? AVPlayerItem,
              let errorLog = playerItem.errorLog(),
              let lastEvent = errorLog.events.last else { return }

        let errorCode = lastEvent.errorStatusCode
        let errorDomain = lastEvent.errorDomain
        let errorComment = lastEvent.errorComment ?? "No details"

        print("🎬 AVPlayerWrapper: Error log entry - Code: \(errorCode), Domain: \(errorDomain), Comment: \(errorComment)")

        // Check for fatal HTTP errors
        // -12939 = byte-range not supported (common with IPTV proxies)
        // -12938 = content not found
        // -12937 = connection failed
        if errorCode == -12939 {
            print("🎬 AVPlayerWrapper: Server doesn't support byte-range requests")
            let message = "Stream format is incompatible with AVPlayer."
            playbackStateSubject.send(.failed(.codecUnsupported(message)))
            errorSubject.send(.codecUnsupported(message))
        } else if errorCode == -12938 {
            // Content-not-found error occasionally appears mid-stream; treat as warning to avoid user-facing failure
            print("🎬 AVPlayerWrapper: Warning - transient content-not-found from server (ignoring)")
        } else if errorCode == -12318 {
            // Segment reported higher bandwidth than variant; warn but don't fail playback
            print("🎬 AVPlayerWrapper: Warning - segment exceeds declared variant bandwidth (continuing)")
        } else if errorCode < 0 && errorCode > -13000 {
            // Other HTTP/network errors in this range
            let message = "Stream error: \(errorComment) (code \(errorCode))"
            playbackStateSubject.send(.failed(.networkError(message)))
            errorSubject.send(.networkError(message))
        }
    }

    @objc private func playerItemNewAccessLogEntry(_ notification: Notification) {
        guard let playerItem = notification.object as? AVPlayerItem,
              let accessLog = playerItem.accessLog(),
              let lastEvent = accessLog.events.last else { return }

        // Log successful connection for debugging
        if lastEvent.numberOfBytesTransferred > 0 {
            print("🎬 AVPlayerWrapper: Streaming - \(lastEvent.numberOfBytesTransferred) bytes, bitrate: \(Int(lastEvent.indicatedBitrate))")
        }
    }

    // MARK: - Lifecycle

    func prepareForReuse() {
        stop()
        _duration = 0
        _isMuted = false
        currentStreamURL = nil
        playbackStateSubject.send(.idle)
        timeSubject.send(0)
    }

    // MARK: - Codec Detection

    /// Attempts to extract codec information from the current player item's asset
    private func detectCodecInfo() -> String? {
        guard let asset = playerItem?.asset else { return nil }

        // Try to get video track info
        let videoTracks = asset.tracks(withMediaType: .video)
        if let videoTrack = videoTracks.first {
            let formatDescriptions = videoTrack.formatDescriptions as? [CMFormatDescription] ?? []
            if let formatDesc = formatDescriptions.first {
                let codecType = CMFormatDescriptionGetMediaSubType(formatDesc)
                let codecString = fourCCToString(codecType)

                // Map common codec types to readable names
                let readableName: String
                switch codecType {
                case kCMVideoCodecType_H264:
                    readableName = "H.264/AVC"
                case kCMVideoCodecType_HEVC:
                    readableName = "H.265/HEVC"
                case kCMVideoCodecType_MPEG4Video:
                    readableName = "MPEG-4"
                case kCMVideoCodecType_MPEG2Video:
                    readableName = "MPEG-2"
                case kCMVideoCodecType_VP9:
                    readableName = "VP9"
                default:
                    readableName = codecString
                }

                return readableName
            }
        }

        return nil
    }

    /// Converts a FourCC code to a readable string
    private func fourCCToString(_ code: FourCharCode) -> String {
        let chars: [Character] = [
            Character(UnicodeScalar((code >> 24) & 0xFF)!),
            Character(UnicodeScalar((code >> 16) & 0xFF)!),
            Character(UnicodeScalar((code >> 8) & 0xFF)!),
            Character(UnicodeScalar(code & 0xFF)!)
        ]
        return String(chars).trimmingCharacters(in: .whitespaces)
    }

    /// Builds error message with codec info if available
    private func buildCompatibilityErrorMessage() -> String {
        if let codec = detectCodecInfo() {
            return "Codec '\(codec)' is incompatible with AVPlayer. Disable 'Use AVPlayer for Dolby Vision' in Settings."
        } else {
            return "This format is incompatible with AVPlayer. Disable 'Use AVPlayer for Dolby Vision' in Settings."
        }
    }

    // MARK: - Sentry Logging

    private func logStreamFailureToSentry(error: Error, errorCode: Int, errorDomain: String, isCompatibilityError: Bool) {
        let event = Event(level: .error)

        // Build a more informative message
        var messageParts: [String] = ["AVPlayer stream failed"]
        messageParts.append("Error: \(error.localizedDescription)")
        messageParts.append("Code: \(errorCode)")
        if let codec = detectCodecInfo() {
            messageParts.append("Codec: \(codec)")
        }
        if let host = currentStreamURL?.host {
            messageParts.append("Host: \(host)")
        }
        if isCompatibilityError {
            messageParts.append("(Compatibility issue)")
        }

        event.message = SentryMessage(formatted: messageParts.joined(separator: " | "))

        // Add tags
        event.tags = [
            "component": "avplayer",
            "error_code": String(errorCode),
            "error_domain": errorDomain,
            "is_compatibility_error": String(isCompatibilityError)
        ]

        // Add extra context
        var extras: [String: Any] = [
            "error_description": error.localizedDescription,
            "error_code": errorCode,
            "error_domain": errorDomain
        ]

        // Add detected codec info
        if let codec = detectCodecInfo() {
            extras["detected_codec"] = codec
            event.tags?["codec"] = codec
        }

        if let url = currentStreamURL {
            // Redact the full URL but keep useful parts
            extras["stream_host"] = url.host ?? "unknown"
            extras["stream_path"] = url.path
            extras["stream_scheme"] = url.scheme ?? "unknown"
        }

        // Add player item info if available
        if let item = playerItem {
            extras["player_item_status"] = String(describing: item.status.rawValue)
            if let asset = item.asset as? AVURLAsset {
                extras["asset_url_scheme"] = asset.url.scheme ?? "unknown"
            }
        }

        event.extra = extras

        SentrySDK.capture(event: event)
        print("🎬 AVPlayerWrapper: Logged stream failure to Sentry (code: \(errorCode))")
    }
}
