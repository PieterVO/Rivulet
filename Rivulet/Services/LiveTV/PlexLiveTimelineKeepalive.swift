// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Keeps a tuned Plex Live TV session alive via `/:/timeline` pings.
///
/// PMS runs each live grab as a rolling subscription with a 300-second
/// stop-grab timer; a timeline report referencing the session resets it
/// (verified: an unreported session dies within minutes, a reported one
/// survives and `state=stopped` releases it immediately).
///
/// Cadence and parameters follow the working-client consensus:
///  - 10s heartbeat, with the FIRST ping delayed 3s — an immediate ping can
///    make the server spawn a duplicate transcode job that 404s.
///  - `ratingKey` is the NUMERIC live-session metadata id from the tune
///    response (EPG-style plex:// keys 404 on this endpoint). Carried on the
///    resolved URL as `rivuletLiveRatingKey` (PMS ignores unknown params).
///  - `time=0&duration=0&playbackTime=<elapsed ms>` — sidesteps the server's
///    "time may not exceed duration" rejection entirely.
///  - `state=stopped` on stop() releases the tuner without waiting for the
///    timeout.
@MainActor
final class PlexLiveTimelineKeepalive {

    private struct Context {
        let serverURL: String
        let authToken: String
        let sessionPath: String
        let sessionIdentifier: String?
        let ratingKey: String?
        let startedAt: Date
    }

    private var context: Context?
    private var heartbeatTask: Task<Void, Never>?

    /// Begin reporting for the session carried by `url`. No-op (and stops any
    /// previous reporting) when the URL doesn't reference a tuned session.
    /// Accepts both URL forms: the raw session playlist
    /// (/livetv/sessions/{uuid}/{consumer}/index.m3u8) and the universal
    /// transcoder (start.m3u8?path=/livetv/sessions/{uuid}).
    func start(url: URL) {
        stop()

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host,
              let token = components.queryItems?
                  .first(where: { $0.name == "X-Plex-Token" })?.value,
              let sessionPath = Self.sessionPath(from: url, components: components) else {
            return
        }

        let port = components.port.map { ":\($0)" } ?? ""
        context = Context(
            serverURL: "\(scheme)://\(host)\(port)",
            authToken: token,
            sessionPath: sessionPath,
            sessionIdentifier: components.queryItems?
                .first(where: { $0.name == "X-Plex-Session-Identifier" })?.value,
            ratingKey: components.queryItems?
                .first(where: { $0.name == "rivuletLiveRatingKey" })?.value,
            startedAt: Date()
        )

        heartbeatTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                guard let self, self.context != nil else { return }
                self.report(state: "playing")
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Final "stopped" report + heartbeat teardown. Releases the tuner
    /// server-side without waiting for the 300s timeout.
    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if context != nil {
            report(state: "stopped")
        }
        context = nil
    }

    private func report(state: String) {
        guard let context else { return }

        let elapsedMs = max(0, Int(Date().timeIntervalSince(context.startedAt) * 1000))
        guard var components = URLComponents(string: "\(context.serverURL)/:/timeline") else { return }
        var items = [
            URLQueryItem(name: "key", value: context.sessionPath),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "hasMDE", value: "1"),
            URLQueryItem(name: "time", value: "0"),
            URLQueryItem(name: "duration", value: "0"),
            URLQueryItem(name: "playbackTime", value: "\(elapsedMs)"),
        ]
        if let ratingKey = context.ratingKey {
            items.insert(URLQueryItem(name: "ratingKey", value: ratingKey), at: 0)
        }
        if let sessionIdentifier = context.sessionIdentifier {
            items.append(URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionIdentifier))
        }
        components.queryItems = items
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.setValue(context.authToken, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(PlexAPI.productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(PlexAPI.platform, forHTTPHeaderField: "X-Plex-Platform")

        Task.detached(priority: .utility) {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    playerDebugLog("📺 Live timeline (\(state)) returned HTTP \(http.statusCode)")
                }
            } catch {
                playerDebugLog("📺 Live timeline (\(state)) failed: \(error.localizedDescription)")
            }
        }
    }

    private static func sessionPath(from url: URL, components: URLComponents) -> String? {
        if url.path.hasPrefix("/livetv/sessions/") {
            let parts = url.path.split(separator: "/")  // [livetv, sessions, uuid, …]
            guard parts.count >= 3 else { return nil }
            return "/livetv/sessions/\(parts[2])"
        }
        if let queryPath = components.queryItems?.first(where: { $0.name == "path" })?.value,
           queryPath.hasPrefix("/livetv/sessions/") {
            return queryPath
        }
        return nil  // Not a tuned Plex session — nothing to keep alive.
    }
}
