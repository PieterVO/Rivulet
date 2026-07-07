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

    /// The set of suppressed fact ids (auto-hidden after enough reports).
    /// Empty set on any failure — suppression is a safety overlay, and failing
    /// open (showing a fact) is acceptable; failing closed is not required.
    func suppressedFactIDs() async -> Set<String> {
        let url = baseURL.appendingPathComponent("insights/suppressed")
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    private func fetchTrivia(path: String) async -> TitleTrivia? {
        let url = baseURL.appendingPathComponent(path)
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return try? JSONDecoder().decode(TitleTrivia.self, from: data)
    }
}
