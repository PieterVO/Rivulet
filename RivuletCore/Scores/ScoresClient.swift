// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ScoresClient.swift
//  Rivulet
//
//  Fetches a league's scoreboard from the insights-api Worker. Every failure
//  is soft: nil, and the scores UI hides or pauses.
//

import Foundation

actor ScoresClient {
    static let shared = ScoresClient()

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
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    func scoreboard(_ league: League) async -> Scoreboard? {
        let url = baseURL.appendingPathComponent("v1/scores/\(league.rawValue)")
        guard let (data, response) = try? await session.attestedData(for: URLRequest(url: url)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? Scoreboard.decode(data)
    }
}
