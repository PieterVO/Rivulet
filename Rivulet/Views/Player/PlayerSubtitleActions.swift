// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated enum PlayerSubtitleSearchResult: Sendable {
    case plex(PlexStream)
    case silo(SiloSubtitleSearchResult, fileID: String, providerID: String)

    var title: String {
        switch self {
        case .plex(let result): return result.title ?? result.displayTitle ?? "Subtitle"
        case .silo(let result, _, _): return result.releaseName.isEmpty ? "Subtitle" : result.releaseName
        }
    }

    var detail: String {
        let parts: [String?]
        switch self {
        case .plex(let result):
            parts = [result.language, result.codec?.uppercased(), result.hearingImpaired == true ? "SDH" : nil,
                     result.forced == true ? "Forced" : nil]
        case .silo(let result, _, _):
            parts = [Locale.current.localizedString(forLanguageCode: result.language) ?? result.language,
                     result.format.uppercased(), result.hearingImpaired ? "SDH" : nil, result.provider]
        }
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

nonisolated enum PlayerSubtitleOperation: Sendable {
    case idle
    case downloading
    case starting
    case job(SiloSubtitleAIJob)
    case activating
    case completed
    case failed(String)

    var detail: String {
        switch self {
        case .idle: return "Choose a Silo subtitle action."
        case .downloading: return "Downloading to Silo…"
        case .starting: return "Starting on Silo…"
        case .job(let job): return job.statusText
        case .activating: return "Selecting the subtitle in Silo…"
        case .completed: return "Subtitle selected."
        case .failed(let message): return message
        }
    }

    var isBusy: Bool {
        switch self {
        case .downloading, .starting, .activating: return true
        case .job(let job): return job.isActive
        default: return false
        }
    }

    var cancellableJobID: String? {
        if case .job(let job) = self, job.isActive { return job.id }
        return nil
    }
}

extension SiloSubtitleAIStatus {
    @MainActor
    func generationOptions(for source: MediaSource, targetLanguage: String) -> [SiloSubtitleGenerationOption] {
        var options: [SiloSubtitleGenerationOption] = []
        let target = Locale.current.localizedString(forLanguageCode: targetLanguage) ?? targetLanguage
        if canTranscribe, !source.audioTracks.isEmpty {
            let index = source.audioTracks.first(where: \.isSelected)?.index ?? -1
            options.append(SiloSubtitleGenerationOption(title: "Transcribe Audio", detail: "Silo · original spoken language",
                                                        kind: .transcribe, sourceIndex: index, targetLanguage: "", fileID: source.id))
            if canTranslate {
                options.append(SiloSubtitleGenerationOption(title: "Generate \(target) from Audio", detail: "Silo · transcribe and translate",
                                                            kind: .transcribeTranslate, sourceIndex: index, targetLanguage: targetLanguage, fileID: source.id))
            }
        }
        if canTranslate {
            let supported: Set<String> = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "text"]
            for track in source.subtitleTracks where supported.contains(track.codec.lowercased()) {
                if let language = track.language, TrackLanguage.normalize(language) == TrackLanguage.normalize(targetLanguage) { continue }
                let language = track.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? track.language ?? "Auto-detect"
                options.append(SiloSubtitleGenerationOption(title: "Translate \(language) to \(target)",
                    detail: [track.title, track.codec.uppercased(), track.isHearingImpaired ? "SDH" : nil]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    kind: .translate, sourceIndex: track.index, targetLanguage: targetLanguage, fileID: source.id))
            }
        }
        return options
    }
}
