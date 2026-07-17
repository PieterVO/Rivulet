// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsTriviaClient.swift
//  Rivulet
//
//  Fetches trivia JSON + the suppressed-fact list from the insights-api
//  Worker. All failures are soft: a missing/uncovered title just yields nil
//  (the Trivia section is then absent), never an error surfaced to the user.
//

import Foundation

actor InsightsTriviaClient {
    static let shared = InsightsTriviaClient()

    private let session: URLSession
    private let baseURL: URL

    init(baseURL: URL = InsightsConfig.apiBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 20
            // Trivia at a given URL is MUTABLE — the pipeline regenerates it
            // in place (new facts, interest scores, etc.). The API sends a
            // 24h `Cache-Control`, so the default policy would pin the first
            // response fetched on-device for a full day and never show a
            // regenerated Top 10. Always revalidate against the origin (the
            // Cloudflare edge cache still absorbs the load); the payload is
            // small and fetched once per playback.
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Trivia for a movie by TMDB id. `nil` on 404 / network failure / decode
    /// failure (all treated as "no trivia available").
    func movieTrivia(tmdbId: Int) async -> TitleTrivia? {
        await fetchTrivia(path: "insights/movie/\(tmdbId)")
    }

    /// Trivia for a TV episode by show TMDB id + season + episode.
    func episodeTrivia(showTmdbId: Int, season: Int, episode: Int) async -> TitleTrivia? {
        await fetchTrivia(path: "insights/tv/\(showTmdbId)/\(season)/\(episode)")
    }

    /// Show-level trivia (production/casting/overall, not tied to an episode).
    /// Used for a show context, or as a fallback for an episode that has no
    /// episode-specific trivia yet.
    func showTrivia(showTmdbId: Int) async -> TitleTrivia? {
        await fetchTrivia(path: "insights/tv/\(showTmdbId)/show")
    }

    /// Rich result variants that distinguish a genuine 404 ("not covered yet" —
    /// safe to trigger generation) from any other failure (network, timeout,
    /// decode error — "unavailable", never trigger generation). Callers that
    /// only need the soft-fail `TitleTrivia?` shape should keep using the
    /// `*Trivia` methods above.
    func movieTriviaResult(tmdbId: Int) async -> TriviaFetchResult {
        await fetchResult(path: "insights/movie/\(tmdbId)")
    }

    func episodeTriviaResult(showTmdbId: Int, season: Int, episode: Int) async -> TriviaFetchResult {
        await fetchResult(path: "insights/tv/\(showTmdbId)/\(season)/\(episode)")
    }

    func showTriviaResult(showTmdbId: Int) async -> TriviaFetchResult {
        await fetchResult(path: "insights/tv/\(showTmdbId)/show")
    }

    /// The set of suppressed fact ids (auto-hidden after enough reports).
    /// Empty set on any failure — suppression is a safety overlay, and failing
    /// open (showing a fact) is acceptable; failing closed is not required.
    func suppressedFactIDs() async -> Set<String> {
        let url = baseURL.appendingPathComponent("insights/suppressed")
        guard let (data, response) = try? await send(URLRequest(url: url)),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    /// Fire-and-forget request asking the pipeline to generate trivia for a
    /// title/episode it doesn't have yet. All failures ignored — this is a
    /// best-effort nudge, never a blocking or error-surfacing call.
    ///
    /// This is the one WRITE endpoint, and the Worker enforces attestation on
    /// it unconditionally (no grace period): it costs us R2 writes and feeds
    /// the generation pipeline, so it is never open to anonymous callers.
    func requestGeneration(_ req: InsightsGenerationRequest) async {
        let url = baseURL.appendingPathComponent("insights/request")
        var r = URLRequest(url: url); r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONEncoder().encode(req)
        _ = try? await send(r)   // fire-and-forget; all failures ignored
    }

    private func fetchTrivia(path: String) async -> TitleTrivia? {
        if case .found(let t) = await fetchResult(path: path) { return t }
        return nil
    }

    private func fetchResult(path: String) async -> TriviaFetchResult {
        let url = baseURL.appendingPathComponent(path)
        guard let (data, response) = try? await send(URLRequest(url: url)),
              let http = response as? HTTPURLResponse else { return .unavailable }
        if http.statusCode == 404 { return .notFound }
        guard http.statusCode == 200,
              let t = try? JSONDecoder().decode(TitleTrivia.self, from: data) else { return .unavailable }
        return .found(t)
    }

    /// Every call to our Worker goes through the shared attested path, which
    /// signs the request and re-enrolls once on a 401.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.attestedData(for: request)
    }
}

/// Result of a trivia fetch, distinguishing a genuine 404 (title/episode not
/// yet covered — safe to trigger generation) from any other failure (network,
/// timeout, decode error — retry naturally later, never fire generation).
enum TriviaFetchResult {
    case found(TitleTrivia)
    case notFound
    case unavailable
}

/// Generation request body posted to `insights/request` (camelCase, per the
/// insights-api contract). Carries only TMDB ids + title/year — no Plex
/// token, no account id, no personal data (Global Constraints).
nonisolated struct InsightsGenerationRequest: Encodable, Sendable {
    let type: String
    let tmdbId: Int
    let season: Int?
    let episode: Int?
    let title: String
    let year: Int?
}
