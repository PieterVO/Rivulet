// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StreamBodyClassifier.swift
//  Rivulet
//
//  Identifies what a stream URL actually returned, for RIVULET-19 diagnostics.
//
//  Why this exists
//  ---------------
//  RIVULET-19 is `HLSVideoEngine: open failed (openFailed(code: -1094995529))`,
//  531 events across 70 users since 2026-01-09, with no release correlation.
//  That code is FFmpeg's AVERROR_INVALIDDATA, and despite the "HLSVideoEngine"
//  name it fires on the aether route at startup: the tag `failed_route: aether`
//  is set on every tagged event. AetherEngine calls `avformat_open_input` with a
//  custom AVIO provider, a nil URL and a nil input format, so FFmpeg has to
//  identify the container purely by probing the first bytes. When the bytes are
//  not media at all the probe fails with exactly this code. The engine already
//  hardcodes a rescue for one non-media body, an `#EXTM3U` manifest, and the
//  comment on that rescue names this same error code. Every OTHER non-media
//  body still dies.
//
//  The codec spread rules out a codec, HDR or container cause: it hits h264,
//  hevc, av1 and mpeg2video, every resolution, SDR and HDR alike. So the bytes
//  are very likely not the media file. What we do NOT know is WHICH non-media
//  body dominates. The leading hypothesis is an expired `X-Plex-Token` yielding
//  a 401 with an HTML or XML body, but nothing in the current telemetry proves
//  it, because the aether route captures no evidence at all about the response.
//  One release carrying this classification settles the question.
//
//  Why a separate pure type
//  ------------------------
//  Byte sniffing is exactly the kind of logic that should be unit-tested without
//  standing up a view model or a network stack, matching `MarkerSkipOutcome`,
//  `StallWatchdogPolicy` and `AetherLoadTimeoutPolicy`.
//
//  Security posture
//  ----------------
//  This type deliberately never returns free text from the body. See
//  `Classification` and `describe(status:contentType:body:)` for the reasoning.
//  The short version is that an error body can embed the request URL, which
//  carries a working `X-Plex-Token`, and IPTV URLs embed credentials directly in
//  the path where no `key=value` redactor can see them. So the output is drawn
//  from a fixed vocabulary rather than sanitized from user data.
//

import Foundation

/// What a byte prefix fetched from a stream URL turned out to be.
///
/// Every case is a compile-time constant string. Nothing derived from the
/// response body ever reaches the raw value, which is what makes this safe to
/// attach to a Sentry event without any redaction pass at all.
enum StreamBodyClassification: String {

    /// An HTML document. The leading RIVULET-19 hypothesis: a Plex error page,
    /// a captive portal, or a reverse proxy 401/403 interstitial.
    case html

    /// A JSON document. Typically a structured API error from Plex or from an
    /// IPTV provider that answers errors in JSON rather than in HTML.
    case json

    /// An XML document that is not HTML. Plex's own error responses are often
    /// XML `MediaContainer` bodies, so this is distinct from `html` on purpose.
    case xml

    /// An HLS manifest. AetherEngine already rescues this specific body at
    /// `AVIOReader.swift`, so seeing it here would mean that rescue is not
    /// firing rather than that the body is unexpected.
    case m3u8

    /// An ISO base media file (MP4, M4V, MOV). This is real media, so seeing it
    /// would refute the bad-body theory for that event and point the
    /// investigation back at the engine's demuxer.
    case mp4

    /// A Matroska or WebM container. Also real media.
    case matroska

    /// An MPEG transport stream. Also real media.
    case mpegts

    /// A Matroska/WebM or MP4 body could not be confirmed but the bytes are not
    /// text either. Recorded separately from `unknown` so a binary-but-
    /// unidentified body is distinguishable from an empty or textual one.
    case binary

    /// The response carried no body at all. A zero-length 200 would explain the
    /// probe failure directly.
    case empty

    /// None of the above signatures matched.
    case unknown
}

/// Sniffs the leading bytes of an HTTP response to decide what kind of body it
/// is, and renders a Sentry-safe one-line summary.
///
/// Pure and `nonisolated`: no networking, no state, no actor hop on the error
/// path.
nonisolated enum StreamBodyClassifier {

    /// How many bytes the caller needs to fetch for `classify` to be reliable.
    ///
    /// Every signature this type recognises lives in the first few bytes, so a
    /// single kilobyte is far more than enough. It is kept small deliberately:
    /// this request only ever runs after a playback failure, and a small ranged
    /// GET is cheap enough that it cannot meaningfully compete with the HLS
    /// fallback for bandwidth.
    static let probeByteCount = 1024

    /// The `Range` header value for a probe request.
    static let probeRangeHeader = "bytes=0-\(probeByteCount - 1)"

    // MARK: - Classification

    /// Identify a response body from its leading bytes.
    ///
    /// Text signatures are matched after skipping leading ASCII whitespace,
    /// because servers routinely emit a newline or a BOM-adjacent blank before
    /// `<!DOCTYPE html>`. Binary signatures are matched at their fixed offsets
    /// with no skipping, since a container's magic number is positional.
    static func classify(_ data: Data) -> StreamBodyClassification {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return .empty }

        // Binary container signatures first. These are positional and cannot be
        // confused with text, so checking them before the text heuristics avoids
        // a stray `<` inside binary payload masquerading as HTML.

        // ISO base media: a `ftyp` box type at offset 4, after the box size.
        if bytes.count >= 8, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return .mp4
        }

        // Matroska and WebM share the EBML header magic 0x1A45DFA3.
        if bytes.count >= 4, bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 {
            return .matroska
        }

        // MPEG-TS: a 0x47 sync byte at offset 0 and again one 188-byte packet
        // later. Requiring the second sync avoids classifying an arbitrary body
        // that merely happens to start with an ASCII "G" as a transport stream.
        if bytes.first == 0x47 {
            if bytes.count > 188 {
                if bytes[188] == 0x47 { return .mpegts }
            } else {
                // Too short to confirm the second sync byte. A lone 0x47 is weak
                // evidence, so fall through rather than claim mpegts.
                return .unknown
            }
        }

        // Text signatures. Skip leading ASCII whitespace so a body that begins
        // with a newline still classifies.
        let trimmed = Array(bytes.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
        guard let first = trimmed.first else { return .empty }

        // HLS manifest: `#EXTM3U`. Checked before the generic text cases because
        // it is the one non-media body AetherEngine already rescues.
        if matchesASCII(trimmed, "#EXTM3U") { return .m3u8 }

        if first == 0x3C {  // '<'
            // Distinguish an XML declaration or a non-HTML XML root from HTML.
            // Plex answers many errors with an XML `MediaContainer`, and knowing
            // which of the two we get changes where the fix goes.
            if matchesASCIICaseInsensitive(trimmed, "<!DOCTYPE HTML") { return .html }
            if matchesASCIICaseInsensitive(trimmed, "<HTML") { return .html }
            if matchesASCII(trimmed, "<?xml") { return .xml }
            if matchesASCII(trimmed, "<Media") { return .xml }
            // A bare `<` that is neither a recognised HTML nor XML opener is
            // still far more likely to be markup than media.
            return .html
        }

        if first == 0x7B || first == 0x5B { return .json }  // '{' or '['

        // Not text-like and no container signature matched. Decide between
        // binary and unknown by whether the prefix is plausibly printable ASCII,
        // which keeps a truncated text error distinguishable from raw bytes.
        let printable = trimmed.prefix(64).filter { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        let sampleCount = min(64, trimmed.count)
        return printable.count == sampleCount ? .unknown : .binary
    }

    // MARK: - Sentry-safe summary

    /// Render a one-line, credential-free summary of a probe result.
    ///
    /// SECURITY: this deliberately contains NO data copied out of the response
    /// body, and no part of the request URL. Only three things go in:
    ///
    ///  1. The HTTP status code, an integer.
    ///  2. The `Content-Type` header, reduced to its media type and matched
    ///     against a fixed allowlist by `safeContentType`.
    ///  3. The classification, whose every value is a compile-time constant.
    ///
    /// A body prefix is NOT included, even a redacted one. The reason is that
    /// `SensitiveDataRedactor` only strips `key=value` query pairs, and the two
    /// most likely credential shapes in an error body defeat exactly that: a
    /// Plex error page can echo the token as bare text or as an XML attribute
    /// with no `=` query syntax around it, and an IPTV provider embeds
    /// `username` and `password` as PATH SEGMENTS (`/live/user/pass/id.ts`)
    /// which no query-pair regex can see. The `.hls` route's existing preflight
    /// does record a 120-character prefix, but it does so against a URL the app
    /// built itself for a Plex transcode session, whereas this probe hits an
    /// arbitrary direct-play or IPTV origin. Since the classification alone
    /// answers the question this diagnostic exists to answer, the prefix buys
    /// nothing and risks a token in Sentry, so it is dropped. When in doubt,
    /// send less.
    static func describe(
        status: Int,
        contentType: String?,
        classification: StreamBodyClassification,
        byteCount: Int
    ) -> String {
        "http=\(status) type=\(safeContentType(contentType)) body=\(classification.rawValue) bytes=\(byteCount)"
    }

    /// Reduce a `Content-Type` header to a fixed vocabulary.
    ///
    /// The header is server-controlled, so it is untrusted text and cannot be
    /// forwarded verbatim. Parameters (`; charset=`, `; boundary=`) are dropped
    /// and the remaining media type is only emitted if it appears in
    /// `knownContentTypes`. Anything else collapses to `other`, so a server that
    /// stuffs a credential into this header cannot leak it through us.
    static func safeContentType(_ raw: String?) -> String {
        guard let raw else { return "none" }
        let mediaType = raw
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !mediaType.isEmpty else { return "none" }
        return knownContentTypes.contains(mediaType) ? mediaType : "other"
    }

    /// The `Content-Type` values worth distinguishing, all of them constants in
    /// this file. Anything outside this set is reported as `other`.
    private static let knownContentTypes: Set<String> = [
        "text/html",
        "text/plain",
        "text/xml",
        "application/xml",
        "application/json",
        "application/x-mpegurl",
        "application/vnd.apple.mpegurl",
        "audio/mpegurl",
        "video/mp4",
        "video/x-matroska",
        "video/webm",
        "video/mp2t",
        "video/quicktime",
        "video/x-msvideo",
        "application/octet-stream",
    ]

    // MARK: - ASCII helpers

    /// Case-sensitive ASCII prefix match against a byte array.
    private static func matchesASCII(_ bytes: [UInt8], _ prefix: String) -> Bool {
        let pattern = Array(prefix.utf8)
        guard bytes.count >= pattern.count else { return false }
        for index in pattern.indices where bytes[index] != pattern[index] {
            return false
        }
        return true
    }

    /// Case-insensitive ASCII prefix match. `prefix` must be given in uppercase.
    private static func matchesASCIICaseInsensitive(_ bytes: [UInt8], _ prefix: String) -> Bool {
        let pattern = Array(prefix.utf8)
        guard bytes.count >= pattern.count else { return false }
        for index in pattern.indices {
            let candidate = bytes[index]
            // Uppercase ASCII letters only; the patterns here contain no other
            // case-sensitive characters.
            let folded = (candidate >= 0x61 && candidate <= 0x7A) ? candidate - 0x20 : candidate
            if folded != pattern[index] { return false }
        }
        return true
    }
}
