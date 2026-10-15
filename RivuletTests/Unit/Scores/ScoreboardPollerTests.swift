// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ScoreboardPollerTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class ScoreboardPollerTests: XCTestCase {

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private actor Calls {
        var leagues: [League] = []
        func add(_ league: League) { leagues.append(league) }
    }

    nonisolated private static func board(_ league: League, games: Int) -> Scoreboard {
        let team = ScoreTeam(abbr: "A", name: "A", short: "A", nickname: "A", location: "A", score: nil, logo: nil)
        return Scoreboard(league: league, fetchedAt: Date(), stale: false, poll: 30,
                          games: (0..<games).map { ScoreGame(id: "\($0)", state: .in, start: Date(), detail: "",
                                                             network: nil, away: team, home: team) })
    }

    func test_refreshSkipsFreshAndEmptyLeagues() async {
        let calls = Calls()
        let clock = Box(Date(timeIntervalSince1970: 0))
        let poller = ScoreboardPoller(fetch: { league in
            await calls.add(league)
            return Self.board(league, games: league == .nfl ? 2 : 0)
        }, now: { clock.value })

        await poller.refreshIfStale(maxAge: 30)
        let first = await calls.leagues
        XCTAssertEqual(Set(first), Set(League.allCases))

        clock.value += 60
        await poller.refreshIfStale(maxAge: 30)
        let second = await calls.leagues.dropFirst(first.count)
        XCTAssertEqual(Array(second), [.nfl], "empty leagues wait for the 10 minute recheck")
        XCTAssertFalse(poller.isPaused)
    }

    func test_failedLeagueWithGamesPauses() async {
        let fail = Box(false)
        let poller = ScoreboardPoller(fetch: { league in
            fail.value ? nil : Self.board(league, games: 1)
        }, now: { Date() })
        await poller.refreshIfStale(maxAge: 0)
        XCTAssertFalse(poller.isPaused)
        fail.value = true
        await poller.refreshIfStale(maxAge: 0)
        XCTAssertTrue(poller.isPaused)
        XCTAssertEqual(poller.boards[.nfl]?.games.count, 1, "last scores stay")
    }

    func test_pollingStopsWithLastSubscriber() async throws {
        let calls = Calls()
        let poller = ScoreboardPoller(fetch: { league in
            await calls.add(league)
            return Self.board(league, games: 1)
        }, now: { Date() })
        var subscription: ScoreboardPoller.Subscription? = poller.subscribe()
        try await Task.sleep(for: .milliseconds(200))
        let polled = await calls.leagues.count
        XCTAssertEqual(polled, League.allCases.count)
        XCTAssertNotNil(subscription)
        subscription = nil
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(poller.isPolling)
    }
}
