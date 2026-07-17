// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsActorLoadCoordinator.swift
//  Rivulet
//
//  Stale-load guard for the in-panel actor view (Docs/superpowers/plans/
//  2026-07-07-insights-in-panel-actor.md, Task B). Selecting a cast member
//  kicks an async `PersonFilmographyProvider.load`; if the user backs out to
//  the cast list or picks a different actor before it resolves, the late
//  result must be dropped rather than overwriting whatever the panel is
//  showing now. A monotonic token is the whole mechanism: each new selection
//  (or a return-to-list) bumps the counter, and a load result is only applied
//  if its token is still the current one when it completes.
//

import Foundation

@MainActor
final class InsightsActorLoadCoordinator {
    private var currentToken = 0

    /// Begin a new selection; returns the token to tag this load with.
    func begin() -> Int {
        currentToken += 1
        return currentToken
    }

    /// True if `token` is still the active selection (apply the result);
    /// false if a newer selection or a return-to-list superseded it (drop).
    func isCurrent(_ token: Int) -> Bool {
        token == currentToken
    }

    /// Called when returning to the list state so a late load is dropped.
    func cancel() {
        currentToken += 1
    }
}
