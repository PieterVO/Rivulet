// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TranscodeSubtitleStream.swift
//  Rivulet
//
//  The hls route's text subtitle: PMS streams the selected track as one ASS
//  document from `/video/:/transcode/universal/subtitles` while the transcode
//  runs, a few lines at a time as the throttled transcoder advances. Cue times
//  are media time whatever the transcode's `offset`. Embedded ASS keeps its
//  own header and styles; SRT arrives converted under a stock header.
//

import Foundation

enum TranscodeSubtitleStream {

    struct Event: Equatable {
        let start: Double
        let end: Double
        /// The libavcodec event line libass and `ASSEventLine` take:
        /// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`.
        let line: String
    }

    /// A `Dialogue:` line as its timing and event line. ReadOrder is always 0:
    /// PMS repeats lines across its chunk boundaries and the overlay dedupes on
    /// start and line.
    nonisolated static func event(fromDialogue line: String) -> Event? {
        guard line.hasPrefix("Dialogue:") else { return nil }
        let fields = line.dropFirst("Dialogue:".count)
            .split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
        guard fields.count == 10, let start = seconds(fields[1]), let end = seconds(fields[2]) else { return nil }
        let layer = fields[0].trimmingCharacters(in: .whitespaces)
        return Event(start: start, end: end, line: (["0", layer] + fields[3...].map(String.init)).joined(separator: ","))
    }

    /// ASS `H:MM:SS.cc`.
    nonisolated static func seconds(_ field: Substring) -> Double? {
        let parts = field.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
            return nil
        }
        let total = h * 3600 + m * 60 + s
        // Server input: NaN or a huge value would trap the overlay's Int64 conversion.
        return total.isFinite && total >= 0 && total < 1e7 ? total : nil
    }

    /// Reads until PMS closes the response. `onHeader` gets everything through
    /// the `[Events]` Format line once, then `onEvent` each dialogue line.
    /// Returns whether a header arrived.
    static func read(_ request: URLRequest,
                     onHeader: (String) -> Void,
                     onEvent: (Event) -> Void) async -> Bool {
        var header: [String] = []
        var headerBytes = 0
        var headerDone = false
        do {
            let (bytes, response) = try await PlexNetworkManager.shared.openEndedBytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            for try await line in bytes.lines {
                if headerDone {
                    if let event = event(fromDialogue: line) { onEvent(event) }
                    continue
                }
                header.append(line)
                headerBytes += line.utf8.count
                // Script info, styles and any embedded fonts; past this the stream is not ASS.
                guard headerBytes < 16 << 20 else { return false }
                if line.hasPrefix("Format:"), header.contains("[Events]") {
                    headerDone = true
                    onHeader(header.joined(separator: "\n") + "\n")
                }
            }
        } catch {
            // A cancelled task or a dropped connection ends the stream the same way.
        }
        return headerDone
    }
}
