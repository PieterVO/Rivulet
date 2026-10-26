// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  On-device speech: the model download, and the recognizer that turns
//  playback audio into timed words (Parakeet TDT-CTC 110M through
//  FluidAudio). The content filter uses the words to mute one word instead
//  of a whole subtitle cue; generated subtitles are written from them.
//

import AVFoundation
import Combine
import FluidAudio
import Foundation
import Sentry

/// Decoded playback audio: mono 48 kHz, stamped on the source axis.
nonisolated struct PlaybackAudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let sourceTime: Double
    /// True when this chunk does not follow the previous one (start, seek, gap).
    let discontinuity: Bool
}

// MARK: - Model

/// The speech model on disk. Downloaded when content filtering is turned on or generated subtitles are first picked.
@MainActor
final class SpeechModelStore: ObservableObject {
    static let shared = SpeechModelStore()

    enum State: Equatable {
        case absent
        case downloading(Double)
        case ready
        case failed
    }

    @Published private(set) var state: State

    nonisolated static let version: AsrModelVersion = .tdtCtc110m

    // ponytail: Hugging Face download into Caches, which tvOS may purge under
    // storage pressure (the next playback downloads it again). An Apple-hosted
    // asset pack (AssetPackManager) is the upgrade when this ships to everyone.
    nonisolated private static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("SpeechModels", isDirectory: true)
            .appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
    }

    private var download: Task<Void, Never>?

    private init() {
        state = AsrModels.modelsExist(at: Self.directory, version: Self.version) ? .ready : .absent
    }

    var statusText: String {
        switch state {
        case .absent: return "Off"
        case .downloading(let fraction): return "\(Int(fraction * 100))%"
        case .ready: return "On"
        case .failed: return "Failed"
        }
    }

    /// Download the model if it isn't on disk. Safe to call repeatedly.
    func prepare() {
        if AsrModels.modelsExist(at: Self.directory, version: Self.version) {
            state = .ready
            return
        }
        guard download == nil else { return }
        state = .downloading(0)
        download = Task {
            do {
                try await AsrModels.download(to: Self.directory, version: Self.version) { progress in
                    Task { @MainActor in
                        if case .downloading = SpeechModelStore.shared.state {
                            SpeechModelStore.shared.state = .downloading(progress.fractionCompleted)
                        }
                    }
                }
                state = .ready
            } catch {
                state = .failed
                SentryBridge.log(.warn, "Content filter: speech model download failed")
                // Keeps trying while the filter or generated subtitles want it.
                try? await Task.sleep(for: .seconds(30))
                download = nil
                if Self.isWanted { prepare() }
                return
            }
            download = nil
        }
    }

    private static var isWanted: Bool {
        SettingsStore.bool(ContentFilterManager.Keys.enabled, default: false)
            || SettingsStore.bool(UniversalPlayerViewModel.generatedSubtitlesFallbackKey, default: false)
    }

    /// Load the model from disk; nil when it isn't there or won't load.
    /// `loadLocal`, not `load`: `load` also fetches a separate 115 MB CTC model.
    nonisolated static func load() async -> AsrModels? {
        try? AsrModels.loadLocal(from: directory, version: version)
    }
}

// MARK: - Recognizer

/// Cuts playback audio into short overlapping windows and transcribes each.
/// Windows are short because the tap reads only ~10 s ahead: a long window
/// would finish after the playhead had already reached its words.
nonisolated enum SpeechWordRecognizer {

    static let window = 4.0
    /// Audio on each side of a window that is decoded for context only; its
    /// words come from the neighbouring window.
    static let context = 0.75

    /// Transcribe `audio` until it ends or the task is cancelled, handing each
    /// window's words and the stretch they cover to `onWords`.
    static func run(models: AsrModels, audio: AsyncStream<PlaybackAudioChunk>,
                    onWords: @escaping @Sendable ([SpokenWord], ClosedRange<Double>) async -> Void) async {
        let asr = AsrManager()
        do { try await asr.loadModels(models) } catch {
            SentryBridge.log(.warn, "Content filter: speech model failed to load")
            return
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        var buffer = WindowBuffer(sampleRate: 48_000)
        /// The last words reported, so words at a window seam aren't reported twice.
        var recent: [SpokenWord] = []

        func transcribe(_ cut: WindowBuffer.Cut) async {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(cut.samples.count)),
                  let channel = pcm.floatChannelData?[0] else { return }
            pcm.frameLength = pcm.frameCapacity
            cut.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
            var state = TdtDecoderState.make(decoderLayers: SpeechModelStore.version.decoderLayers)
            guard let result = try? await asr.transcribe(pcm, decoderState: &state),
                  let timings = result.tokenTimings else { return }
            let words = buildWordTimings(from: timings).compactMap { word -> SpokenWord? in
                let start = cut.start + word.startTime
                // A word before a pause carries the pause in its last token's
                // duration ("shit." ran 1.2 s): end it on its letters, capped.
                let letters = timings.filter {
                    $0.startTime >= word.startTime && $0.endTime <= word.endTime && $0.token.contains(where: \.isLetter)
                }
                let spoken = letters.map(\.endTime).max() ?? word.endTime
                let end = cut.start + min(spoken, word.startTime + 0.2 + 0.09 * Double(word.word.filter(\.isLetter).count))
                guard cut.keeps.contains((start + end) / 2) else { return nil }
                let confidence = timings
                    .filter { $0.startTime >= word.startTime && $0.endTime <= word.endTime }
                    .map(\.confidence).min() ?? 0
                return SpokenWord(text: word.word, start: start, end: end, confidence: confidence)
            }
            let fresh = SpokenWordAlignment.droppingSeamRepeat(words, after: recent)
            recent = Array((recent + fresh).suffix(4))
            await onWords(fresh, cut.keeps)
        }

        for await chunk in audio {
            guard !Task.isCancelled else { break }
            if chunk.discontinuity {
                if let rest = buffer.flush() { await transcribe(rest) }
                recent = []
            }
            guard let data = chunk.buffer.floatChannelData?[0] else { continue }
            buffer.append(UnsafeBufferPointer(start: data, count: Int(chunk.buffer.frameLength)),
                          at: chunk.sourceTime, restart: chunk.discontinuity)
            while let cut = buffer.nextWindow(length: window, context: context) {
                await transcribe(cut)
            }
        }
        if !Task.isCancelled, let rest = buffer.flush() { await transcribe(rest) }
        await asr.cleanup()
    }
}

/// Mono samples waiting to be transcribed, and the window cutting. Pure.
nonisolated struct WindowBuffer {
    struct Cut {
        let samples: [Float]
        /// Source time of the first sample.
        let start: Double
        /// The stretch whose words this cut reports.
        let keeps: ClosedRange<Double>
    }

    let sampleRate: Double
    private(set) var samples: [Float] = []
    private(set) var start: Double = 0
    /// Words before this were reported by an earlier cut.
    private var reportedUntil: Double?

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    mutating func append(_ new: UnsafeBufferPointer<Float>, at time: Double, restart: Bool) {
        if restart || samples.isEmpty {
            samples = []
            start = time
            reportedUntil = nil
        }
        samples.append(contentsOf: new)
    }

    /// The next full window, keeping `context` behind it for the one after.
    mutating func nextWindow(length: Double, context: Double) -> Cut? {
        let count = Int(length * sampleRate)
        guard samples.count >= count else { return nil }
        let end = start + length
        let keepFrom = reportedUntil ?? start
        let keepTo = end - context
        let cut = Cut(samples: Array(samples.prefix(count)), start: start, keeps: keepFrom...keepTo)
        reportedUntil = keepTo
        let drop = Int((keepTo - context - start) * sampleRate)
        samples.removeFirst(max(0, min(drop, samples.count)))
        start += Double(max(0, drop)) / sampleRate
        return cut
    }

    /// Whatever is left, reported to its end (before a jump to new audio).
    mutating func flush() -> Cut? {
        defer { samples = []; reportedUntil = nil }
        guard samples.count >= Int(sampleRate) else { return nil }
        let end = start + Double(samples.count) / sampleRate
        let keepFrom = reportedUntil ?? start
        guard end > keepFrom else { return nil }
        return Cut(samples: samples, start: start, keeps: keepFrom...end)
    }
}
