// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ScoreboardPoller.swift
//  Rivulet
//
//  Every league's latest scoreboard, shared by the scores pane and the
//  multiview scores layout. Polls only while something on screen holds a
//  subscription; the player otherwise asks for an occasional refresh to
//  decide whether to offer scores at all.
//

import Foundation
import Combine

@MainActor
final class ScoreboardPoller: ObservableObject {
    static let shared = ScoreboardPoller()

    @Published private(set) var boards: [League: Scoreboard] = [:]
    /// The last fetch of a league that has games failed.
    @Published private(set) var isPaused = false

    /// A league with no games today is rechecked this rarely.
    static let emptyRecheck: TimeInterval = 10 * 60

    private let fetch: @Sendable (League) async -> Scoreboard?
    private let now: () -> Date
    private var fetchedAt: [League: Date] = [:]
    private var inFlight: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var subscribers = 0

    init(fetch: @escaping @Sendable (League) async -> Scoreboard? = { await ScoresClient.shared.scoreboard($0) },
         now: @escaping () -> Date = Date.init) {
        self.fetch = fetch
        self.now = now
    }

    /// Keeps scores polling while held. Release by dropping it.
    final class Subscription {
        private weak var poller: ScoreboardPoller?
        fileprivate init(_ poller: ScoreboardPoller) { self.poller = poller }
        deinit {
            let poller = poller
            Task { @MainActor in poller?.release() }
        }
    }

    func subscribe() -> Subscription {
        subscribers += 1
        if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled, let self {
                    let interval = self.interval
                    await self.refreshIfStale(maxAge: interval - 1)
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        }
        return Subscription(self)
    }

    private func release() {
        subscribers -= 1
        guard subscribers <= 0 else { return }
        subscribers = 0
        loop?.cancel()
        loop = nil
    }

    var isPolling: Bool { loop != nil }

    /// The worker's requested interval; 30 s until it says otherwise.
    var interval: TimeInterval {
        TimeInterval(boards.values.map(\.poll).max() ?? 30)
    }

    /// Fetches each league whose board is older than `maxAge`, or than
    /// `emptyRecheck` for a league with no games.
    func refreshIfStale(maxAge: TimeInterval) async {
        if let inFlight { return await inFlight.value }
        let due = League.allCases.filter { league in
            guard let at = fetchedAt[league] else { return true }
            let age = boards[league]?.games.isEmpty == false ? maxAge : max(maxAge, Self.emptyRecheck)
            return now().timeIntervalSince(at) >= age
        }
        guard !due.isEmpty else { return }
        let task = Task { [fetch] in
            let results = await withTaskGroup(of: (League, Scoreboard?).self) { group in
                for league in due { group.addTask { (league, await fetch(league)) } }
                return await group.reduce(into: [(League, Scoreboard?)]()) { $0.append($1) }
            }
            self.apply(results)
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func apply(_ results: [(League, Scoreboard?)]) {
        var failed = false
        for (league, board) in results {
            if let board {
                boards[league] = board
                fetchedAt[league] = now()
            } else if boards[league]?.games.isEmpty == false {
                failed = true
            } else {
                // Unknown or empty league: try again at the empty recheck.
                fetchedAt[league] = now()
            }
        }
        isPaused = failed
    }
}
