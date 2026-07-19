// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentFilterParsers.swift
//  Rivulet
//
//  Parsers for imported, time-coded filter lists:
//    - MCF  (Movie Content Filter, text/mcf+vtt): an open, WebVTT-based format
//           where each cue's payload carries `category=severity` and an
//           optional `channel`. Spec: moviecontentfilter.com/specification
//    - EDL  (Edit Decision List): the simple `start end action` format emitted
//           by cleanvid / Filterflix / the Kodi mute-profanity add-on, and used
//           by Kodi/Comskip/MythTV for skip + mute.
//
//  The MCF parser reuses the app's existing VTTParser to read cue timings, then
//  interprets each cue's text as a filter directive — so we get robust WebVTT
//  timestamp handling for free.
//

import Foundation

enum ContentFilterParseError: Error {
    case empty
    case unrecognizedFormat
}

enum ContentFilterFormat {
    case mcf
    case edl

    /// Best-effort format detection from a URL extension, then content.
    static func detect(url: URL?, content: String) -> ContentFilterFormat? {
        switch url?.pathExtension.lowercased() {
        case "mcf": return .mcf
        case "edl": return .edl
        default: break
        }
        let head = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("WEBVTT") { return .mcf }
        // EDL: first non-empty line is "number number number".
        if let firstLine = head.split(separator: "\n").first,
           EDLFilterParser.looksLikeEDLLine(String(firstLine)) {
            return .edl
        }
        return nil
    }
}

/// Dispatches to the right parser and returns a normalized `ContentFilterList`.
enum ContentFilterParser {
    static func parse(content: String, url: URL?) throws -> ContentFilterList {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContentFilterParseError.empty
        }
        switch ContentFilterFormat.detect(url: url, content: content) {
        case .mcf: return try MCFFilterParser.parse(content)
        case .edl: return try EDLFilterParser.parse(content)
        case nil: throw ContentFilterParseError.unrecognizedFormat
        }
    }
}

// MARK: - MCF

enum MCFFilterParser {

    /// Parse an `text/mcf+vtt` document. Cue timings come from the shared
    /// `VTTParser`; each cue's text is the filter directive.
    static func parse(_ content: String) throws -> ContentFilterList {
        let track = try VTTParser().parse(content)
        var regions: [FilterRegion] = []
        var nextID = 0

        for cue in track.cues {
            // A cue's payload can carry several `key=value` tokens across one or
            // more lines: `category=severity` pairs plus an optional `channel`.
            let tokens = cue.text
                .replacingOccurrences(of: "\n", with: " ")
                .split(separator: " ")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }

            var channel: String?
            var pairs: [(key: String, value: String)] = []
            for token in tokens {
                let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[0] == "channel" {
                    channel = parts[1]
                } else {
                    pairs.append((parts[0], parts[1]))
                }
            }

            for pair in pairs {
                let category = FilterCategory.matching(pair.key)
                let severity = FilterSeverity(mcf: pair.value)
                let action = actionFor(channel: channel, category: category)
                regions.append(FilterRegion(
                    id: nextID,
                    start: cue.startTime,
                    end: cue.endTime,
                    category: category,
                    severity: severity,
                    action: action
                ))
                nextID += 1
            }
        }

        return ContentFilterList(regions: regions)
    }

    /// `channel=audio` → mute (only the sound is objectionable); `video` or
    /// `audiovisual` → skip. Absent channel falls back to the category default.
    private static func actionFor(channel: String?, category: FilterCategory) -> FilterAction {
        switch channel {
        case "audio": return .mute
        case "video", "audiovisual", "both": return .skip
        default: return category.defaultAction
        }
    }
}

// MARK: - EDL

enum EDLFilterParser {

    /// Parse a whitespace-delimited EDL. Each line: `start end action [category]`.
    /// action 0 = cut/skip, 1 = mute, 2 = scene marker (ignored), 3 = commercial
    /// (skip). An optional 4th token names a category for finer control.
    static func parse(_ content: String) throws -> ContentFilterList {
        var regions: [FilterRegion] = []
        var nextID = 0

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 3,
                  let start = Double(fields[0]),
                  let end = Double(fields[1]),
                  let action = Int(fields[2]),
                  end > start else {
                continue
            }

            let filterAction: FilterAction
            switch action {
            case 1: filterAction = .mute
            case 0, 3: filterAction = .skip
            default: continue  // 2 = scene marker, or unknown → ignore
            }

            // Optional 4th token: category name. Otherwise bucket as `.other`,
            // which the master toggle governs.
            let category: FilterCategory = fields.count >= 4
                ? FilterCategory.matching(fields[3])
                : .other

            regions.append(FilterRegion(
                id: nextID,
                start: start,
                end: end,
                category: category,
                severity: .moderate,
                action: filterAction
            ))
            nextID += 1
        }

        return ContentFilterList(regions: regions)
    }

    /// True if a line looks like `number number number …` (EDL detection).
    static func looksLikeEDLLine(_ line: String) -> Bool {
        let fields = line.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 3 else { return false }
        return Double(fields[0]) != nil && Double(fields[1]) != nil && Int(fields[2]) != nil
    }
}
