// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SensitiveDataRedactor.swift
//  Rivulet
//
//  Strips credentials out of anything on its way to a diagnostics sink.
//
//  Plex authenticates with `X-Plex-Token` as a URL QUERY PARAMETER, not a
//  header, so any URL we log or attach to an error event carries a working
//  credential for that user's Plex account. IPTV/Xtream providers are worse:
//  their M3U and EPG URLs commonly carry `username`/`password` in the query.
//
//  Two things reach Sentry, and both need covering:
//    1. Values we attach ourselves (`scope.setExtra(url.absoluteString, ...)`).
//    2. Events the SDK builds itself — `enableCaptureFailedRequests` attaches
//       the failing request URL, and NSError descriptions embed the URL too.
//  Call sites can only fix (1), so the real guarantee is the `beforeSend` hook
//  in RivuletApp, which runs this over every outgoing event. Call sites are
//  still cleaned up so we don't ship secrets to a sink that merely scrubs them.
//
//  `nonisolated` to match SentryBridge: this runs on the error path from any
//  isolation context and must not cost an actor hop.
//

import Foundation

nonisolated enum SensitiveDataRedactor {

    /// Substituted for any value that would otherwise carry a credential.
    static let redactedValue = "[redacted]"

    /// Query-parameter names whose VALUES are secrets. Matched case-insensitively.
    /// `X-Plex-Token` is the Plex account/server token; the rest are the common
    /// IPTV/Xtream credential and session parameter names.
    private static let secretQueryKeys = [
        "x-plex-token",
        "password",
        "passwd",
        "pass",
        "pwd",
        "username",
        "token",
        "auth",
        "authorization",
        "api_key",
        "apikey",
        "x-api-key",
        "access_token",
        "refresh_token",
        "mac",
        "signature",
    ]

    /// Ordered `(pattern, template)` scrubs. Quoted forms run first so the
    /// `key=value` pass never sees a half-matched `accessToken="…"`.
    private static let scrubs: [(NSRegularExpression, String)] = {
        let keys = secretQueryKeys
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let secretName = "[A-Za-z_-]*(?:token|password|passwd|apikey|api_key|secret)"
        let specs: [(String, String)] = [
            // JSON: "accessToken":"…" (plex.tv /resources bodies).
            ("\"(\(secretName))\"\\s*:\\s*\"[^\"]*\"", "\"$1\":\"\(redactedValue)\""),
            // XML attribute: accessToken="…" or '…'.
            ("\\b(\(secretName))\\s*=\\s*([\"'])[^\"']*\\2", "$1=$2\(redactedValue)$2"),
            // Query string: X-Plex-Token=…
            ("(\(keys))=[^&\\s\"'<>]+", "$1=\(redactedValue)"),
            // Xtream path credentials: /live/<user>/<pass>/<id>.ts
            ("/(live|movie|series|timeshift)/[^/?#\\s\"'<>]+/[^/?#\\s\"'<>]+/",
             "/$1/\(redactedValue)/\(redactedValue)/"),
            // Xtream short form: host/<user>/<pass>/<id>.ts
            ("(://[^/\\s\"'<>]+)/[^/?#\\s\"'<>]+/[^/?#\\s\"'<>]+/(\\d+\\.(?:ts|m3u8|mp4|mkv|avi|flv))",
             "$1/\(redactedValue)/\(redactedValue)/$2"),
            // URL userinfo: scheme://user:pass@host
            ("://[^/\\s:@\"'<>]+:[^/\\s@\"'<>]+@", "://\(redactedValue)@"),
        ]
        return specs.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { ($0, template) }
        }
    }()

    /// Returns `text` with every credential replaced.
    ///
    /// Key names are preserved (`X-Plex-Token=[redacted]`) so events stay
    /// diagnosable — we can still see WHICH parameters a failing request carried,
    /// just not their values.
    static func redact(_ text: String) -> String {
        scrubs.reduce(text) { text, scrub in
            scrub.0.stringByReplacingMatches(
                in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: scrub.1)
        }
    }

    /// Whether a header or field NAME holds a secret (`X-Plex-Token`, `Authorization`).
    static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return secretQueryKeys.contains(lower) || ["token", "password", "secret", "api-key"].contains { lower.contains($0) }
    }

    /// Optional-preserving variant. Deliberately NOT an overload of `redact`:
    /// with both a `String` and a `String?` overload in scope, a call whose
    /// argument is itself generic (e.g. `String(x.prefix(500))`) can't pick one
    /// and fails to typecheck.
    static func redactOptional(_ text: String?) -> String? {
        text.map(redact)
    }

    /// A log-safe rendering of a URL: scheme, host, port, and path, with the
    /// entire query reduced to its key names.
    ///
    /// Prefer this over `url.absoluteString` at every diagnostics call site.
    static func safeURLString(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return redact(url.absoluteString)
        }
        var base = ""
        if let scheme = components.scheme { base += "\(scheme)://" }
        base += components.host ?? "unknown"
        if let port = components.port { base += ":\(port)" }
        base = redact(base + components.path)

        guard let items = components.queryItems, !items.isEmpty else { return base }
        // Keep the shape of the query (which params were sent) without values.
        // Plex transcode failures are diagnosed from WHICH profile params were
        // present, never from the token.
        let keys = items.map(\.name).joined(separator: ",")
        return "\(base)?[\(keys)]"
    }

    /// Optional variant, named distinctly for the same reason as
    /// `redactOptional`. Renders a missing URL as `"unknown"`.
    static func safeURLStringOptional(_ url: URL?) -> String {
        url.map(safeURLString) ?? "unknown"
    }
}
