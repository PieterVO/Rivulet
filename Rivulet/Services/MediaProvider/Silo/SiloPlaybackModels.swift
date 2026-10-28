// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated struct SiloPlaybackCapabilities: Decodable, Sendable {
    let state: String
    let allowed: Bool
    let installationId: String?
    let protocolVersions: [Int]
    let features: [String]
    let deliveries: [String]
}

nonisolated struct SiloPlaybackStart: Encodable, Sendable {
    let installationId: String
    let protocolVersion = 3
    let clientFeatures = ["playback_plan_v3", "sequenced_progress_v1", "plan_source_duration_v1", "embedded_subtitles_v1"]
    let fileId: String
    let profileId: String
    let playbackAttemptId: String
    let qualityPreference = "auto"
    let subtitleFidelityPreference = "compatible"
    let clientCapabilities: SiloCodecCapabilities
    var clientPlaybackContext: SiloPlaybackContext
    let allowAlternateVersions: Bool
    let startPosition: Double
    var bandwidthCapKbps: Int?
    let audioTrackId: String?
    let audioTrackIndex: Int?
    let subtitleTrackId: String?
    let subtitleTrackIndex: Int?
    let progressPersistence = "server"
}

nonisolated struct SiloCodecCapabilities: Encodable, Sendable {
    // FFmpeg/Aether decode-family declarations, not platform-attested native
    // decoders or HDMI passthrough. Strict video tiers require video_decode.
    let videoEvidence = "declared"
    let audioEvidence = "declared"
    let codecsVideo: [String]
    let codecsVideoHardware: [String]
    let codecsAudio: [String]
    let containers: [String]
    let hdr: Bool
    let hdrDetails: SiloHDRCapabilities
    let maxResolution = "2160p"
}

nonisolated struct SiloHDRCapabilities: Encodable, Sendable {
    let hdr10: Bool
    let hdr10Plus: Bool
    let hlg: Bool
    let dolbyVisionProfiles: [Int]
}

nonisolated struct SiloPlaybackContext: Encodable, Sendable {
    let protocolVersion = 3
    let formFactor = "tv"
    let appVersion: String
    let appBuild: String
    let device: SiloDeviceContext
    let output: SiloOutputContext
    let deliveries: [String: SiloDeliveryCapabilities]
}

nonisolated struct SiloDeviceContext: Encodable, Sendable {
    let manufacturer = "Apple"
    let model: String
    let osVersion: String
    let platform = "tvos"
}

nonisolated struct SiloOutputContext: Encodable, Sendable {
    let hdrDetails: SiloHDRCapabilities
}

nonisolated struct SiloDeliveryCapabilities: Encodable, Sendable {
    let enabled = true
    let supportedOnDevice = true
    let containers: [String]
    let videoCodecs: [String]
    let audioDecodeCodecs: [String]
    let audioPassthroughCodecs: [String] = []
    let subtitles: SiloSubtitleCapabilities
    var features: [String] = []
    let authHeaderRefresh = false
    var validatedClaims: [String] = []
    let transformations: [String] = []
    let hdrDetails: SiloHDRCapabilities
    let maxChannels = 8
}

nonisolated struct SiloSubtitleCapabilities: Encodable, Sendable {
    let embeddedText: Bool
    let sidecarText: Bool
    let assStyling: Bool
    let embeddedBitmap: Bool
    let sidecarBitmap = false
    let fontAttachments: Bool
    var nativeEmbedded: [SiloNativeEmbeddedSubtitleCapabilities] = []
}

nonisolated struct SiloNativeEmbeddedSubtitleCapabilities: Encodable, Sendable {
    let container: String
    let codecs: [String]
    let trackIdentity = "ffmpeg_stream_index"
    let assStyling = true
    let fontAttachments = true
}

nonisolated struct SiloPlaybackDecision: Decodable, Sendable {
    let protocolVersion: Int
    let outcome: String
    let sessionId: String?
    let playbackPlan: SiloPlaybackPlan?
    let terminal: SiloPlaybackTerminal?
}

nonisolated struct SiloPlaybackTerminal: Decodable, Sendable {
    let reason: String
    let message: String
    let retryable: Bool
}

nonisolated struct SiloPlaybackPlan: Decodable, Sendable {
    let protocolVersion: Int
    let planId: String
    let planAttemptKey: String
    let sessionId: String?
    let delivery: String
    let expiresAt: String?
    let stream: SiloPlanStream
    let timeline: SiloPlanTimeline
    let effectiveMediaFileId: String
    let selectedTracks: SiloSelectedTracks
    let subtitle: SiloPlanSubtitle
    let source: SiloPlanSource
}

nonisolated struct SiloPlanStream: Decodable, Sendable {
    let url: String
    let `protocol`: String
    let headers: [String: String]
    let headerRefresh: String
    let container: String?
}

nonisolated struct SiloPlanTimeline: Decodable, Sendable {
    let sourceStartSeconds: Double
    let streamOriginSeconds: Double
    let playerStartSeconds: Double
    let timelineOffsetSeconds: Double
    let canSeekAnywhere: Bool
    let seekRestoration: String
}

nonisolated struct SiloSelectedTracks: Codable, Sendable {
    let audio: SiloTrackIdentity?
    let subtitle: SiloTrackIdentity?
}

nonisolated struct SiloTrackIdentity: Codable, Sendable {
    let id: String
    let index: Int?
}

nonisolated struct SiloPlanSubtitle: Decodable, Sendable {
    let mode: String
    let trackId: String?
    let artifact: SiloSubtitleArtifact?
    let embedded: SiloEmbeddedSubtitle?
    let hlsRendition: SiloHLSSubtitleRendition?
    let inventory: [SiloPlanSubtitleTrack]
}

nonisolated struct SiloSubtitleArtifact: Decodable, Sendable {
    let url: String
    let mimeType: String
    let format: String
    let timingOriginSeconds: Double
}

nonisolated struct SiloEmbeddedSubtitle: Decodable, Sendable {
    let streamIndex: Int
    let containerTrackId: String?
}

nonisolated struct SiloHLSSubtitleRendition: Decodable, Sendable {
    let groupId: String
    let name: String
    let format: String
    let mimeType: String
}

nonisolated struct SiloPlanSubtitleTrack: Decodable, Sendable {
    let trackId: String
    let combinedIndex: Int
    let source: String
    let codec: String?
    let language: String?
    let label: String?
    let forced: Bool
    let `default`: Bool
    let hearingImpaired: Bool
    let delivery: String
    let url: String?
}

nonisolated struct SiloPlanSource: Decodable, Sendable {
    let mediaFileId: String
    let durationSeconds: Double?
}

nonisolated struct SiloPlaybackSession: Sendable {
    let installationID: String
    let sessionID: String
    let fileID: String
    let timelineOffset: Double
    let ref: MediaItemRef
    let request: SiloPlaybackStart
    let plan: SiloPlaybackPlan
    let lifetime: SiloPlaybackLifetime
    let relay: SiloMediaRelay
    var isReplanning = false
}

nonisolated struct SiloPlaybackReplan: Encodable, Sendable {
    let installationId: String
    let protocolVersion = 3
    let playbackAttemptId: String
    let replanRequestId: String
    let failedPlanId: String
    let planAttemptId: String
    let planAttemptKey: String
    let attemptedPlanKeys: [String] = []
    let attemptCount = 1
    let qualityPreference = "auto"
    let positionSeconds: Double
    let selectedTracks: SiloSelectedTracks
    let clientCapabilities: SiloCodecCapabilities
    let clientPlaybackContext: SiloPlaybackContext
    let clientFeatures = ["playback_plan_v3", "sequenced_progress_v1", "plan_source_duration_v1", "embedded_subtitles_v1"]
    let bandwidthCapKbps: Int?
    let operation: String
}

nonisolated struct SiloPlaybackMutation: Decodable, Sendable {
    let outcome: String
}

nonisolated struct SiloPlaybackProgress: Encodable, Sendable {
    let installationId: String
    let sequence: Int
    let position: Double
    let isPaused: Bool
}

nonisolated struct SiloPlaybackStop: Encodable, Sendable {
    let installationId: String
    let stopId: String
    let sequence: Int
    let position: Double
    let isPaused: Bool
}

/// Retires an unplayed plan without writing a fictitious zero resume sample.
nonisolated struct SiloPlaybackDiscard: Encodable, Sendable {
    let installationId: String
    let stopId: String
}

nonisolated struct SiloAudioPreference: Encodable, Sendable {
    let audioTrackIndex: Int
    let audioLanguage: String?
    let trackSignature: SiloAudioSignature
}

nonisolated struct SiloAudioSignature: Encodable, Sendable {
    let language: String?
    let codec: String?
    let channels: Int?
    let layout: String?
    let title: String?
    let embeddedTitle: String?
    let `default`: Bool
}

nonisolated struct SiloSubtitlePreference: Encodable, Sendable {
    let subtitleTrackIndex: Int
    let subtitleLanguage: String?
    let subtitleMode: String
    let externalSubtitlePath: String?
    let trackSignature: SiloSubtitleSignature?
}

nonisolated struct SiloProgressSyncBody: Encodable, Sendable {
    let items: [SiloProgressSyncItem]
}

nonisolated struct SiloProgressSyncItem: Encodable, Sendable {
    let mediaItemId: String
    let positionMs: Int64
    let durationMs: Int64
    let forceOverwrite = true
}

nonisolated struct SiloProgressSyncResult: Decodable, Sendable {
    let items: [SiloProgressSyncOutcome]
}

nonisolated struct SiloProgressSyncOutcome: Decodable, Sendable {
    let status: String
    let failure: SiloProgressSyncError?
}

nonisolated struct SiloProgressSyncError: Decodable, Sendable {
    let type: String
    let detail: String?
}
