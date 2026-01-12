//
//  NowPlayingService.swift
//  Rivulet
//
//  Service for integrating with system Now Playing center.
//  Updates MPNowPlayingInfoCenter and handles MPRemoteCommandCenter events.
//

import Foundation
import MediaPlayer
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

    // MARK: - Initialization

    private init() {
        setupRemoteCommandCenter()
    }

    // MARK: - Public API

    /// Attach to a player view model to sync Now Playing state
    func attach(to viewModel: UniversalPlayerViewModel) {
        // Detach from previous if any
        detach()

        self.viewModel = viewModel

        // Set initial Now Playing info
        updateNowPlayingInfo(
            metadata: viewModel.metadata,
            currentTime: viewModel.currentTime,
            duration: viewModel.duration,
            isPlaying: viewModel.playbackState == .playing,
            serverURL: viewModel.serverURL,
            authToken: viewModel.authToken
        )

        // Subscribe to playback state changes
        viewModel.$playbackState
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] state in
                guard let self, let viewModel else { return }
                self.updatePlaybackRate(isPlaying: state == .playing)
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
                self.updateDuration(duration, currentTime: viewModel.currentTime)
            }
            .store(in: &cancellables)

        print("🎵 NowPlaying: Attached to player")
    }

    /// Detach from the current view model and clear Now Playing
    func detach() {
        cancellables.removeAll()
        viewModel = nil
        artworkTask?.cancel()
        artworkTask = nil
        clearNowPlayingInfo()
        print("🎵 NowPlaying: Detached from player")
    }

    // MARK: - Remote Command Center Setup

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.viewModel?.resume()
            }
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.viewModel?.pause()
            }
            return .success
        }

        // Toggle play/pause
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.viewModel?.togglePlayPause()
            }
            return .success
        }

        // Skip forward (10 seconds)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [10]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                guard let viewModel = self?.viewModel else { return }
                let newTime = min(viewModel.currentTime + skipEvent.interval, viewModel.duration)
                await viewModel.seek(to: newTime)
            }
            return .success
        }

        // Skip backward (10 seconds)
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [10]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                guard let viewModel = self?.viewModel else { return }
                let newTime = max(viewModel.currentTime - skipEvent.interval, 0)
                await viewModel.seek(to: newTime)
            }
            return .success
        }

        // Change playback position (scrubbing/seeking)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                await self?.viewModel?.seek(to: positionEvent.positionTime)
            }
            return .success
        }

        // Disable commands we don't support
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changeRepeatModeCommand.isEnabled = false
        commandCenter.changeShuffleModeCommand.isEnabled = false

        print("🎵 NowPlaying: Remote command center configured")
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

        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = nowPlayingInfo
        infoCenter.playbackState = isPlaying ? .playing : .paused

        // Load artwork asynchronously
        loadArtwork(for: metadata, serverURL: serverURL, authToken: authToken)

        print("🎵 NowPlaying: Updated info - \(metadata.title ?? "Unknown"), \(Int(currentTime))/\(Int(duration))s")
    }

    private func updatePlaybackRate(isPlaying: Bool) {
        let infoCenter = MPNowPlayingInfoCenter.default()
        var nowPlayingInfo = infoCenter.nowPlayingInfo ?? [:]
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        infoCenter.nowPlayingInfo = nowPlayingInfo
        infoCenter.playbackState = isPlaying ? .playing : .paused
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
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
        print("🎵 NowPlaying: Cleared")
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
