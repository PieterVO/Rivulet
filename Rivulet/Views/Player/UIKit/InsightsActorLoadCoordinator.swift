// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsActorLoadCoordinator.swift
//  Rivulet
//
//  Stale-load guard for the in-panel actor view: each selection or return to the
//  list bumps a token, and a filmography load applies only if its token is current.
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
