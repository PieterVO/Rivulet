// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// How sound and picture start on a software-route live join, as the Sentry `live.av`
// transaction (#319). `first_frame_pts_gap` and `first_frame_wall_gap` measure a mid-GOP
// join (audio-led clock); `vlead_min`, the engine's vLead from 5 s in, below zero means the decoder lags.
// Same rules as LiveJoinTelemetry: no URLs, no `engine.diagnostics.liveTelemetry`.

import AVFoundation
import Foundation
import Sentry

/// Collects the start of one fullscreen live join. The engine calls in on its
/// own threads (log lines on any, frames on the decode thread), so all state
/// sits behind the lock.
nonisolated final class LiveAVCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let source: String
    private let scan: String
    private let audio: LiveAudioRoute
    private var codec: String?
    private var armPTS: Double?
    private var armUptime: TimeInterval?
    private var firstFramePTS: Double?
    private var firstFrameUptime: TimeInterval?
    private var videoLeadMin: Double?
    private var lines: [String] = []

    /// Engine lines kept for the report. None of them carries a URL.
    private static let keptPrefixes = [
        "[AetherEngine] dispatch:",
        "[AudioOutput] seekClock",
        "[AudioOutput] first enqueue",
        "[AudioOutput] AE#549",
        "[SWDiag]",
    ]
    private static let maxLines = 40

    /// The URL is read for its categories here and not kept.
    init(url: URL) {
        source = LiveJoinTelemetry.sourceKind(for: url)
        scan = LiveJoinTelemetry.scanKind(for: url)
        audio = LiveAudioRoute.current()
    }

    func setCodec(_ codec: String?) {
        lock.withLock { self.codec = codec }
    }

    func ingest(line: String, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard Self.keptPrefixes.contains(where: { line.hasPrefix($0) }) else { return }
        lock.lock()
        defer { lock.unlock() }
        if lines.count < Self.maxLines { lines.append(String(line.prefix(300))) }
        // The first seek that sets the clock running is the arm: the engine
        // logs it just before it starts the synchronizer at that time.
        if armPTS == nil, line.hasPrefix("[AudioOutput] seekClock"),
           let to = Self.number(after: "to=", in: line),
           let rate = Self.number(after: "rate=", in: line), rate > 0 {
            armPTS = to
            armUptime = uptime
        } else if line.hasPrefix("[SWDiag]"), let armUptime, uptime >= armUptime + 5,
                  let lead = Self.number(after: "vLead=", in: line) {
            videoLeadMin = min(videoLeadMin ?? lead, lead)
        }
    }

    /// A frame handed to the display layer, in presentation order.
    func frame(pts: Double, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        defer { lock.unlock() }
        guard firstFramePTS == nil, pts.isFinite else { return }
        firstFramePTS = pts
        firstFrameUptime = uptime
    }

    /// nil until the clock has started and a picture has reached the layer.
    func sample() -> LiveAVStartSample? {
        lock.lock()
        defer { lock.unlock() }
        guard let armPTS, let armUptime, let firstFramePTS, let firstFrameUptime else { return nil }
        return LiveAVStartSample(
            source: source,
            scan: scan,
            codec: codec ?? "none",
            audio: audio,
            firstFramePTSGap: firstFramePTS - armPTS,
            firstFrameWallGap: firstFrameUptime - armUptime,
            videoLeadMin: videoLeadMin,
            engineLog: lines
        )
    }

    /// The number after `key` up to the next space ("vLead=-0.42 ..." → -0.42).
    static func number(after key: String, in line: String) -> Double? {
        guard let range = line.range(of: key) else { return nil }
        return Double(line[range.upperBound...].prefix { !$0.isWhitespace })
    }
}

nonisolated struct LiveAVStartSample {
    let source: String
    let scan: String
    let codec: String
    let audio: LiveAudioRoute
    let firstFramePTSGap: TimeInterval
    let firstFrameWallGap: TimeInterval
    let videoLeadMin: TimeInterval?
    let engineLog: [String]
}

/// Where the sound goes, as categories only: never a device name.
nonisolated struct LiveAudioRoute {
    let output: String
    let outputCount: Int
    let latency: TimeInterval

    static func current() -> LiveAudioRoute {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        return LiveAudioRoute(output: outputs.first.map { kind($0.portType) } ?? "none",
                              outputCount: outputs.count,
                              latency: session.outputLatency)
    }

    private static func kind(_ port: AVAudioSession.Port) -> String {
        switch port {
        case .airPlay: return "airplay"
        case .HDMI: return "hdmi"
        case .bluetoothA2DP, .bluetoothLE: return "bluetooth"
        default: return "other"
        }
    }

    /// Tags the output kind (filterable) and measures the rest.
    func record(on span: any Span) {
        span.setTag(value: output, key: "live.audio_out")
        span.setMeasurement(name: "audio_outputs", value: NSNumber(value: outputCount))
        span.setMeasurement(name: "output_latency", value: NSNumber(value: latency * 1000),
                            unit: MeasurementUnitDuration.millisecond)
    }
}

enum LiveAVTelemetry {
    static func report(_ sample: LiveAVStartSample) {
        guard let transaction = SentryBridge.startTransaction(name: "live.av", operation: "live.av") else { return }
        transaction.setTag(value: sample.source, key: "live.source")
        transaction.setTag(value: sample.scan, key: "live.scan")
        transaction.setTag(value: sample.codec, key: "live.codec")
        sample.audio.record(on: transaction)
        let ms = MeasurementUnitDuration.millisecond
        transaction.setMeasurement(name: "first_frame_pts_gap",
                                   value: NSNumber(value: sample.firstFramePTSGap * 1000), unit: ms)
        transaction.setMeasurement(name: "first_frame_wall_gap",
                                   value: NSNumber(value: sample.firstFrameWallGap * 1000), unit: ms)
        if let lead = sample.videoLeadMin {
            transaction.setMeasurement(name: "vlead_min", value: NSNumber(value: lead * 1000), unit: ms)
        }
        transaction.setData(value: sample.engineLog, key: "engine_log")
        transaction.finish()
    }
}
