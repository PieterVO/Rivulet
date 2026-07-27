// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerProtocol.swift
//  Rivulet
//
//  Shared playback contract used by RivuletPlayer and its view model integration.
//

import Foundation
import Combine

// MARK: - Playback State

enum UniversalPlaybackState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case buffering
    case ended
    case failed(PlayerError)

    var isActive: Bool {
        switch self {
        case .playing, .paused, .buffering:
            return true
        default:
            return false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Stable short label for the Sentry App Hang `playback_state` tag
    /// (RIVULET-41). No associated values so it stays low-cardinality.
    var appHangLabel: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .ready: return "ready"
        case .playing: return "playing"
        case .paused: return "paused"
        case .buffering: return "buffering"
        case .ended: return "ended"
        case .failed: return "failed"
        }
    }
}

// MARK: - Player Error

enum PlayerError: Error, Equatable, Sendable {
    case invalidURL
    case loadFailed(String)
    case networkError(String)
    case codecUnsupported(String)
    case unknown(String)

    /// Technical description for logging and Sentry - includes internal details
    var technicalDescription: String {
        switch self {
        case .invalidURL:
            return "Invalid media URL"
        case .loadFailed(let message):
            return "Failed to load media: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .codecUnsupported(let codec):
            return "Unsupported codec: \(codec)"
        case .unknown(let message):
            return "Playback error: \(message)"
        }
    }

    /// User-friendly description shown in the UI
    var userFacingDescription: String {
        switch self {
        case .invalidURL:
            return "This video couldn't be played. The link may be invalid."
        case .loadFailed(let message):
            if message.contains("HLS transcode session failed") {
                return "Your Plex server is taking too long to prepare the video. Please try again."
            } else if message.contains("transcode") {
                return "Your server couldn't prepare this video for playback. It may be busy with other streams."
            } else if message.contains("CoreMediaErrorDomain") || message.contains("-16172") {
                return "The stream from your server couldn't be played. The server may still be preparing the video."
            } else if message.contains("loading failed") {
                return "The stream couldn't be loaded. Check that your server is running and reachable."
            }
            return "This video couldn't be loaded. Please check your connection and try again."
        case .networkError:
            return "Couldn't connect to the server. Please check your network connection."
        case .codecUnsupported:
            return "This video format isn't supported on this device."
        case .unknown(let message):
            if message.contains("CoreMediaErrorDomain") || message.contains("-16172") {
                return "The stream from your server couldn't be played. The server may still be preparing the video."
            }
            return "Something went wrong during playback. Please try again."
        }
    }

    /// Whether the user should be offered a retry option
    var isRetryable: Bool {
        switch self {
        case .loadFailed, .networkError, .unknown:
            return true
        case .invalidURL, .codecUnsupported:
            return false
        }
    }

    /// For Error protocol conformance - uses technical description
    var localizedDescription: String {
        technicalDescription
    }
}

// MARK: - Cancellation

/// Whether an error is an ordinary task/URL cancellation rather than a real
/// playback failure. The user backing out of the preview carousel, or picking
/// a different item, cancels whatever load was in flight — that must not be
/// wrapped into a `PlayerError`, reported to Sentry, or used to trigger the
/// HLS fallback (RIVULET-19). Both spellings are needed: structured
/// concurrency throws `CancellationError`, URLSession throws NSURLError -999,
/// and a cancelled load can surface as either depending on how far it got.
func isCancellationError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
    return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
}

// MARK: - Player Protocol

/// Shared playback interface for the app's video pipeline.
@MainActor
protocol PlayerProtocol: AnyObject {
    // MARK: - Playback State
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var bufferedTime: TimeInterval { get }
    var playbackRate: Float { get set }

    // MARK: - State Publishers
    var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> { get }
    var timePublisher: AnyPublisher<TimeInterval, Never> { get }
    var errorPublisher: AnyPublisher<PlayerError, Never> { get }

    // MARK: - Playback Controls
    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?) async throws
    func play()
    func pause()
    func stop()
    func seek(to time: TimeInterval) async
    func seekRelative(by seconds: TimeInterval) async

    // MARK: - Track Management
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    var currentAudioTrackId: Int? { get }
    var currentSubtitleTrackId: Int? { get }
    func selectAudioTrack(id: Int)
    func selectSubtitleTrack(id: Int?)
    func disableSubtitles()

    // MARK: - Lifecycle
    func prepareForReuse()
}

// MARK: - Default Implementations

extension PlayerProtocol {
    func seekRelative(by seconds: TimeInterval) async {
        let newTime = max(0, min(currentTime + seconds, duration))
        await seek(to: newTime)
    }

    func disableSubtitles() {
        selectSubtitleTrack(id: nil)
    }

    func load(url: URL, startTime: TimeInterval?) async throws {
        try await load(url: url, headers: nil, startTime: startTime)
    }
}
