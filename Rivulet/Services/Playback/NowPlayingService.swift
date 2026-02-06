//
//  NowPlayingService.swift
//  Rivulet
//
//  Service for integrating with system Now Playing center.
//  Updates MPNowPlayingInfoCenter and handles MPRemoteCommandCenter events.
//

import Foundation
import MediaPlayer
import AVFoundation
import Combine
import UIKit

/// Service that manages system Now Playing integration.
/// Updates the Now Playing info center and handles remote command events.
@MainActor
final class NowPlayingService: ObservableObject {

    // MARK: - Singleton

    static let shared = NowPlayingService()

    // MARK: - Private State

    private var cancellables = Set<AnyCancellable>()
    private weak var viewModel: UniversalPlayerViewModel?
    private var artworkTask: Task<Void, Never>?
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkURL: String?
    private var interruptionObserver: NSObjectProtocol?
    private var inputCoordinator: PlaybackInputCoordinator?
    /// Track if we've set Now Playing info with valid duration (> 0)
    /// This prevents the system from ignoring our Now Playing registration
    private var hasValidNowPlayingInfo: Bool = false

    // MARK: - Initialization

    private init() {
        // Don't configure audio session here - do it when attaching to a player
        // Configuring at app launch causes OSStatus error -50
        setupInterruptionHandling()
        setupRemoteCommandCenter()
    }

    // MARK: - Audio Session Configuration

    /// Ensure audio session is active before setting Now Playing info.
    /// This is required for tvOS to register us as the Now Playing app.
    private func ensureAudioSessionActive() {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
        } catch {
            print("🎵 NowPlaying: Could not set audio category: \(error.localizedDescription)")
        }

        do {
            try session.setActive(true)
            print("🎵 NowPlaying: Audio session active for Now Playing registration")
        } catch {
            print("🎵 NowPlaying: Failed to activate audio session: \(error.localizedDescription)")
        }
    }

    // MARK: - Audio Session Interruption Handling

    /// Set up observer for audio session interruptions (e.g., phone calls, other apps)
    private func setupInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleInterruption(notification)
            }
        }
        print("🎵 NowPlaying: Interruption handling configured")
    }

    /// Handle audio session interruptions
    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // Interruption began - system is pausing our audio
            // Don't explicitly pause the player - let the system handle it
            // This prevents the "video pauses when opening Control Center" issue
            print("🎵 NowPlaying: Interruption began")

        case .ended:
            // Interruption ended - check if we should resume
            print("🎵 NowPlaying: Interruption ended")
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("🎵 NowPlaying: System suggests resuming playback")
                    viewModel?.resume()
                }
            }

        @unknown default:
            break
        }
    }

    // MARK: - Public API

    /// Initialize the Now Playing service early at app launch.
    /// This ensures the singleton is created and audio session category is configured.
    func initialize() {
        // Audio session is configured when attach() is called
        print("🎵 NowPlaying: Service initialized")
    }

    /// Attach to a player view model to sync Now Playing state
    func attach(to viewModel: UniversalPlayerViewModel, inputCoordinator: PlaybackInputCoordinator? = nil) {
        // Detach from previous if any
        detach()

        self.viewModel = viewModel
        self.inputCoordinator = inputCoordinator

        // Note: We use MPNowPlayingInfoCenter.default() and MPRemoteCommandCenter.shared()
        // MPNowPlayingSession requires AVPlayer instances, which we don't have with MPV
        // The shared instances should work for Now Playing integration

        // CRITICAL: Ensure audio session is active BEFORE setting Now Playing info
        // This is required for tvOS to register us as the Now Playing app
        ensureAudioSessionActive()

        // CRITICAL: Set preliminary Now Playing info BEFORE playback starts
        // tvOS only registers apps as "Now Playing" if info is set before play() is called
        setPreliminaryNowPlayingInfo(
            metadata: viewModel.metadata,
            serverURL: viewModel.serverURL,
            authToken: viewModel.authToken
        )

        // Track whether we've updated with actual duration from player
        hasValidNowPlayingInfo = false

        // Subscribe to playback state changes
        viewModel.$playbackState
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] state in
                guard let self, let viewModel else { return }

                print("🎵 NowPlaying: Playback state changed to \(state)")

                switch state {
                case .playing:
                    // ALWAYS update rate and state immediately when playing starts
                    // This is critical for Control Center to show the correct state
                    self.updatePlaybackRateAndState(isPlaying: true)

                    // If we have valid duration, update full info with actual duration
                    if viewModel.duration > 0 {
                        self.updateNowPlayingInfo(
                            metadata: viewModel.metadata,
                            currentTime: viewModel.currentTime,
                            duration: viewModel.duration,
                            isPlaying: true,
                            serverURL: viewModel.serverURL,
                            authToken: viewModel.authToken
                        )
                        self.hasValidNowPlayingInfo = true
                    }

                case .paused:
                    // Update rate and state for paused
                    self.updatePlaybackRateAndState(isPlaying: false)

                case .loading, .buffering:
                    // Don't update rate for loading/buffering - keep previous state
                    break

                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Subscribe to time updates
        viewModel.$currentTime
            .receive(on: RunLoop.main)
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self, weak viewModel] time in
                guard let self, let viewModel else { return }
                self.updateElapsedTime(time, duration: viewModel.duration)
            }
            .store(in: &cancellables)

        // Subscribe to duration updates
        viewModel.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] duration in
                guard let self, let viewModel else { return }

                // If we haven't set valid Now Playing info yet and now have valid duration while playing,
                // set the full Now Playing info now
                if !self.hasValidNowPlayingInfo && duration > 0 && viewModel.playbackState == .playing {
                    print("🎵 NowPlaying: Duration available (\(Int(duration))s) - setting full info now")
                    self.updateNowPlayingInfo(
                        metadata: viewModel.metadata,
                        currentTime: viewModel.currentTime,
                        duration: duration,
                        isPlaying: true,
                        serverURL: viewModel.serverURL,
                        authToken: viewModel.authToken
                    )
                    self.hasValidNowPlayingInfo = true
                } else {
                    self.updateDuration(duration, currentTime: viewModel.currentTime)
                }
            }
            .store(in: &cancellables)

        print("🎵 NowPlaying: Attached to player")
    }

    /// Detach from the current view model and clear Now Playing
    /// Note: We intentionally do NOT deactivate the audio session here.
    /// Per WWDC17 guidance, the session should remain active while the app could receive remote commands.
    func detach() {
        cancellables.removeAll()
        viewModel = nil
        inputCoordinator = nil
        artworkTask?.cancel()
        artworkTask = nil
        hasValidNowPlayingInfo = false
        clearNowPlayingInfo()
        print("🎵 NowPlaying: Detached from player")
    }

    // MARK: - Remote Command Center Setup

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.dispatchInputAction(.play)
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.dispatchInputAction(.pause)
            return .success
        }

        // Toggle play/pause
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.dispatchInputAction(.playPause)
            return .success
        }

        // Skip forward (10 seconds)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: InputConfig.tapSeekSeconds)]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            self?.dispatchInputAction(.seekRelative(seconds: skipEvent.interval))
            return .success
        }

        // Skip backward (10 seconds)
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: InputConfig.tapSeekSeconds)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            self?.dispatchInputAction(.seekRelative(seconds: -skipEvent.interval))
            return .success
        }

        // Change playback position (scrubbing/seeking)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.dispatchInputAction(.seekAbsolute(positionEvent.positionTime))
            return .success
        }

        // Seek forward (IR remote FF button - dedicated fast forward buttons)
        // This is different from skipForward - it's triggered by holding dedicated FF button on some remotes
        // Receives beginSeeking when button is pressed, endSeeking when released
        commandCenter.seekForwardCommand.isEnabled = true
        commandCenter.seekForwardCommand.addTarget { [weak self] event in
            guard let seekEvent = event as? MPSeekCommandEvent else {
                return .commandFailed
            }
            switch seekEvent.type {
            case .beginSeeking:
                print("🎵 NowPlaying: seekForward beginSeeking")
                self?.dispatchInputAction(.scrubNudge(forward: true))
            case .endSeeking:
                print("🎵 NowPlaying: seekForward endSeeking")
                // Keep current hold-seek behavior: no auto commit on release.
            @unknown default:
                break
            }
            return .success
        }

        // Seek backward (IR remote RW button - dedicated rewind buttons)
        // This is different from skipBackward - it's triggered by holding dedicated RW button on some remotes
        commandCenter.seekBackwardCommand.isEnabled = true
        commandCenter.seekBackwardCommand.addTarget { [weak self] event in
            guard let seekEvent = event as? MPSeekCommandEvent else {
                return .commandFailed
            }
            switch seekEvent.type {
            case .beginSeeking:
                print("🎵 NowPlaying: seekBackward beginSeeking")
                self?.dispatchInputAction(.scrubNudge(forward: false))
            case .endSeeking:
                print("🎵 NowPlaying: seekBackward endSeeking")
                // Keep current hold-seek behavior: no auto commit on release.
            @unknown default:
                break
            }
            return .success
        }

        // Disable commands we don't support
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changeRepeatModeCommand.isEnabled = false
        commandCenter.changeShuffleModeCommand.isEnabled = false

        print("🎵 NowPlaying: Remote command center configured (shared)")
    }

    private func dispatchInputAction(_ action: PlaybackInputAction) {
        if let inputCoordinator {
            inputCoordinator.handle(action: action, source: .mpRemoteCommand)
            return
        }

        guard let viewModel else { return }

        switch action {
        case .play:
            viewModel.resume()
        case .pause:
            viewModel.pause()
        case .playPause:
            if viewModel.isScrubbing {
                Task { await viewModel.commitScrub() }
            } else {
                viewModel.togglePlayPause()
            }
        case .seekRelative(let seconds):
            Task { await viewModel.seekRelative(by: seconds) }
        case .seekAbsolute(let time):
            Task { await viewModel.seek(to: time) }
        case .scrubNudge(let forward):
            viewModel.scrubInDirection(forward: forward)
        case .scrubCommit:
            Task { await viewModel.commitScrub() }
        case .scrubCancel:
            viewModel.cancelScrub()
        default:
            break
        }
    }

    // MARK: - Now Playing Info Updates

    private func updateNowPlayingInfo(
        metadata: PlexMetadata,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        serverURL: String,
        authToken: String
    ) {
        var nowPlayingInfo = [String: Any]()

        // Title
        nowPlayingInfo[MPMediaItemPropertyTitle] = metadata.title ?? "Unknown"

        // For episodes, set artist as show name and album as season
        if metadata.type == "episode" {
            if let showName = metadata.grandparentTitle {
                nowPlayingInfo[MPMediaItemPropertyArtist] = showName
            }
            if let seasonNum = metadata.parentIndex {
                nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Season \(seasonNum)"
            }
        } else if metadata.type == "movie" {
            // For movies, use year as artist if available
            if let year = metadata.year {
                nowPlayingInfo[MPMediaItemPropertyArtist] = String(year)
            }
        }

        // Duration and elapsed time
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        // Media type
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        // Explicitly set playback state for tvOS Control Center
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        // Load artwork asynchronously
        loadArtwork(for: metadata, serverURL: serverURL, authToken: authToken)

        print("🎵 NowPlaying: Updated info - \(metadata.title ?? "Unknown"), \(Int(currentTime))/\(Int(duration))s, playing: \(isPlaying)")
    }

    /// Legacy method - prefer updatePlaybackRateAndState() for state changes
    private func updatePlaybackRate(isPlaying: Bool) {
        // Only update rate if we already have Now Playing info set
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo, !nowPlayingInfo.isEmpty else {
            print("🎵 NowPlaying: Skipping rate update - no info set yet")
            return
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func updateElapsedTime(_ time: TimeInterval, duration: TimeInterval) {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func updateDuration(_ duration: TimeInterval, currentTime: TimeInterval) {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        print("🎵 NowPlaying: Cleared")
    }

    /// Set Now Playing info BEFORE playback starts - critical for tvOS.
    /// This registers us as the "Now Playing app" before play() is called.
    /// Uses estimated duration from Plex metadata; will be updated when actual duration is available.
    private func setPreliminaryNowPlayingInfo(
        metadata: PlexMetadata,
        serverURL: String,
        authToken: String
    ) {
        var nowPlayingInfo = [String: Any]()

        // Title
        nowPlayingInfo[MPMediaItemPropertyTitle] = metadata.title ?? "Unknown"

        // For episodes, set artist as show name and album as season
        if metadata.type == "episode" {
            if let showName = metadata.grandparentTitle {
                nowPlayingInfo[MPMediaItemPropertyArtist] = showName
            }
            if let seasonNum = metadata.parentIndex {
                nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Season \(seasonNum)"
            }
        } else if metadata.type == "movie" {
            // For movies, use year as artist if available
            if let year = metadata.year {
                nowPlayingInfo[MPMediaItemPropertyArtist] = String(year)
            }
        }

        // Use Plex metadata duration (milliseconds -> seconds) as estimate
        // Will be updated with actual duration when player reports it
        let estimatedDuration = Double(metadata.duration ?? 0) / 1000.0
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = estimatedDuration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        // Media type
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        // Explicitly set playback state - we're about to play
        MPNowPlayingInfoCenter.default().playbackState = .paused

        print("🎵 NowPlaying: Preliminary info set for '\(metadata.title ?? "Unknown")' (estimated duration: \(Int(estimatedDuration))s)")

        // Load artwork asynchronously
        loadArtwork(for: metadata, serverURL: serverURL, authToken: authToken)
    }

    /// Update playback rate in Now Playing info AND set explicit playback state.
    /// This should be called whenever play/pause state changes.
    private func updatePlaybackRateAndState(isPlaying: Bool) {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            print("🎵 NowPlaying: Cannot update rate/state - no info set")
            return
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        print("🎵 NowPlaying: Rate/state updated - isPlaying: \(isPlaying)")
    }

    // MARK: - Artwork Loading

    private func loadArtwork(for metadata: PlexMetadata, serverURL: String, authToken: String) {
        // Determine artwork URL - prefer thumb, fall back to art
        let artworkPath = metadata.thumb ?? metadata.art ?? metadata.grandparentThumb
        guard let artworkPath else { return }

        // Check if we already have this artwork cached
        let fullURL = "\(serverURL)\(artworkPath)?X-Plex-Token=\(authToken)"
        if fullURL == cachedArtworkURL, let cachedArtwork {
            var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            nowPlayingInfo[MPMediaItemPropertyArtwork] = cachedArtwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            return
        }

        // Cancel any existing artwork load
        artworkTask?.cancel()

        artworkTask = Task {
            guard let url = URL(string: fullURL) else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)

                guard !Task.isCancelled else { return }

                guard let image = UIImage(data: data) else { return }

                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

                // Cache the artwork
                self.cachedArtwork = artwork
                self.cachedArtworkURL = fullURL

                // Update Now Playing info with artwork
                var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

                print("🎵 NowPlaying: Artwork loaded")
            } catch {
                if !Task.isCancelled {
                    print("🎵 NowPlaying: Artwork load failed - \(error.localizedDescription)")
                }
            }
        }
    }
}
