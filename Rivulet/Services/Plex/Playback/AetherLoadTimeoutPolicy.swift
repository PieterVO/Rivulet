// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Deadline for the Aether startup load, and the error it throws, so a load that
//  never returns falls back to HLS instead of spinning forever (#245).
//

import Foundation

enum AetherLoadTimeoutPolicy {

    /// How long to wait for `AetherPlayer.load` before falling back to HLS. Generous, since a
    /// remote 4K remux with a FLAC encode can take tens of seconds; larger would push the worst
    /// case past two minutes once the HLS preflight's own retries are added.
    static let startupLoadDeadline: TimeInterval = 60

    /// Thrown when `startupLoadDeadline` expires. Not a cancellation error, because the
    /// fallback skips anything `isCancellationError` accepts. Carries no URL, since stream
    /// URLs hold tokens and must never reach Sentry.
    struct TimedOut: Error, CustomStringConvertible {
        let seconds: TimeInterval

        var description: String {
            "Aether startup load did not return within \(Int(seconds))s"
        }

        var localizedDescription: String { description }
    }

    /// Sentry reason string for a fallback caused by the deadline.
    ///
    /// Kept distinct from `aether_startup_load_failed` so a hang and a thrown
    /// startup error do not merge into one issue. They have different causes
    /// and different fixes, and #245 is only measurable if the hang has its
    /// own name.
    static let fallbackReason = "aether_startup_timeout"
}

/// What the engine does to a given audio codec on the aether route.
///
/// Exists so the INFO sheet can tell the truth. Some codecs reach the decoder
/// as the file stored them, others are re-encoded to FLAC on-device before
/// they are packaged into the HLS segments AVPlayer consumes. Both are
/// on-device work with no server session behind them, which is why the sheet
/// used to describe them identically, but they are not the same thing and the
/// difference is exactly what #245 reporters were trying to see.
enum AetherAudioDelivery {

    /// Codecs the engine passes through untouched, per `AetherPlayer.load`'s
    /// `audioBridgeMode: .lossless` note. Everything not listed here (TrueHD,
    /// DTS, DTS-HD MA, MP3, Opus and friends) is re-encoded to FLAC.
    ///
    /// Stored lowercased. `dca` is FFmpeg's name for the DTS family and is
    /// absent for the same reason DTS is: it gets the FLAC encode.
    static let streamCopiedCodecs: Set<String> = [
        "aac", "ac3", "eac3", "ec3",
    ]

    /// Whether the engine re-encodes this codec instead of copying it.
    static func isReencoded(codec: String?) -> Bool {
        guard let codec else { return false }
        let normalized = codec.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        guard !normalized.isEmpty else { return false }
        return !streamCopiedCodecs.contains(normalized)
    }
}
