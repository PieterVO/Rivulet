// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  RatingsClient.swift
//  Rivulet
//
//  Review scores from the insights-api Worker (MDBList behind it), keyed by
//  TMDB id only. Every failure is soft: an empty list.
//

import Foundation

actor RatingsClient {
    static let shared = RatingsClient()

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

    /// Scores for a movie or show; empty for other kinds or without a TMDB id.
    func ratings(for detail: MediaItemDetail) async -> [MediaRating] {
        let type: String
        switch detail.item.kind {
        case .movie: type = "movie"
        case .show: type = "show"
        default: return []
        }
        guard let id = detail.externalIDs["tmdb"], !id.isEmpty, id.allSatisfy(\.isNumber) else { return [] }
        let url = baseURL.appendingPathComponent("v1/ratings/\(type)/\(id)")
        guard let (data, response) = try? await session.attestedData(for: URLRequest(url: url)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Self.decode(data)
    }

    private struct Payload: Decodable {
        struct Entry: Decodable { let source: String; let value: Double }
        let ratings: [Entry]
    }

    /// Maps the Worker's native scales onto `MediaRating`'s 0–10.
    nonisolated static func decode(_ data: Data) -> [MediaRating] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return MediaRating.ordered(payload.ratings.map { entry in
            switch entry.source {
            case "tomatoes": MediaRating(entry.value / 10, source: .rottenTomatoes)
            case "popcorn": MediaRating(entry.value / 10, source: .rottenTomatoesAudience)
            case "imdb": MediaRating(entry.value, source: .imdb)
            case "metacritic": MediaRating(entry.value / 10, source: .metacritic)
            case "letterboxd": MediaRating(entry.value * 2, source: .letterboxd)
            case "tmdb": MediaRating(entry.value / 10, source: .tmdb)
            default: nil
            }
        })
    }
}
