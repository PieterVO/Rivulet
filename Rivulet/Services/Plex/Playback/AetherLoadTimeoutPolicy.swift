// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AetherLoadTimeoutPolicy.swift
//  Rivulet
//
//  Deadline policy for the Aether startup load, plus the sentinel error the
//  deadline throws.
//
//  Issue #245: movies with TrueHD 7.1 or DTS-HD MA 7.1 audio sometimes stick
//  on the loading spinner forever. Those codecs cannot be stream-copied, so
//  the engine re-encodes them to FLAC while it builds the first HLS segments,
//  which makes startup throughput-sensitive and occasionally non-terminating.
//  The host awaited `AetherPlayer.load` bare, so a load that never returned
//  never threw, the existing HLS fallback never ran, and the UI sat in
//  `.loading` with no exit. The reporter's own workaround, backing out and
//  playing again, is exactly what the fallback does automatically once the
//  wait is bounded.
//
//  Kept as a separate pure type so the deadline value and, more importantly,
//  the not-a-cancellation property of the error are testable without standing
//  up a view model.
//

import Foundation

enum AetherLoadTimeoutPolicy {

    /// How long the host waits for `AetherPlayer.load` to return before it
    /// gives up and falls back to the Plex HLS transcode.
    ///
    /// Chosen generous on purpose. The failure this bounds is an indefinite
    /// hang, so the only cost of waiting too long is a slower recovery, while
    /// the cost of waiting too little is cutting off a start that would have
    /// succeeded. A remote 4K remux over a slow WAN link, with a FLAC encode
    /// running ahead of the first segments, can legitimately take tens of
    /// seconds to produce a playable manifest. Sixty seconds sits well past
    /// any start we have observed succeed and well short of the point where a
    /// user has already given up and pressed Menu.
    ///
    /// Budget it against what happens next: the fallback runs its own HLS
    /// preflight, which polls up to eight times with backoff before it
    /// concedes. A larger deadline here pushes the worst-case total wait past
    /// two minutes, which is why this is not larger still.
    static let startupLoadDeadline: TimeInterval = 60

    /// Error thrown when `startupLoadDeadline` expires.
    ///
    /// This deliberately does NOT use `CancellationError`, and deliberately
    /// does not carry a URL. Two traps sit behind that.
    ///
    /// First, the catch that drives the HLS fallback returns early for
    /// anything `isCancellationError` recognises, because an ordinary
    /// cancellation means the user left the player and must not trigger a
    /// fallback or a Sentry report. A timeout is the opposite: it is a real
    /// startup failure and it MUST reach the fallback. So the error has to be
    /// a type that `isCancellationError` rejects, which means not
    /// `CancellationError`, not `NSURLErrorDomain` code -999, and not
    /// `NSCocoaErrorDomain` `NSUserCancelledError`. A plain Swift error type
    /// bridges to `NSError` with this module's own domain, so all three of
    /// those checks fail and the fallback runs.
    ///
    /// Second, stream URLs never travel to Sentry. Plex URLs carry account
    /// tokens and IPTV paths embed credentials, so the message stays a fixed
    /// string with no interpolated URL at all.
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
