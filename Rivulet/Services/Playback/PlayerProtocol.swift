//
//  PlayerProtocol.swift
//  Rivulet
//
//  Unified interface for video player implementations (AVPlayer, VLCKit)
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
}

// MARK: - Player Error

enum PlayerError: Error, Equatable, Sendable {
    case invalidURL
    case loadFailed(String)
    case networkError(String)
    case codecUnsupported(String)
    case unknown(String)

    var localizedDescription: String {
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
}

// MARK: - Player Protocol

/// Unified interface for all player implementations
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
