// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsActorLoadCoordinatorTests.swift
//  RivuletTests
//
//  Unit coverage for the stale-load guard behind the in-panel actor view
//  (Docs/superpowers/plans/2026-07-07-insights-in-panel-actor.md, Task B).
//  `InsightsActorLoadCoordinator` owns a monotonic selection token so a slow
//  `PersonFilmographyProvider.load` that resolves after the user has moved on
//  (picked another actor, or backed out to the cast list) is dropped instead
//  of clobbering the panel with stale data.
//

import XCTest
@testable import Rivulet

@MainActor
final class InsightsActorLoadCoordinatorTests: XCTestCase {

    func testBeginReturnsIncreasingTokens() {
        let coordinator = InsightsActorLoadCoordinator()
        let first = coordinator.begin()
        let second = coordinator.begin()
        let third = coordinator.begin()
        XCTAssertLessThan(first, second)
        XCTAssertLessThan(second, third)
    }

    func testIsCurrentTrueForLatestToken() {
        let coordinator = InsightsActorLoadCoordinator()
        let token = coordinator.begin()
        XCTAssertTrue(coordinator.isCurrent(token))
    }

    func testIsCurrentFalseForSupersededToken() {
        let coordinator = InsightsActorLoadCoordinator()
        let stale = coordinator.begin()
        let fresh = coordinator.begin()
        XCTAssertFalse(coordinator.isCurrent(stale))
        XCTAssertTrue(coordinator.isCurrent(fresh))
    }

    func testCancelDropsThePreviouslyCurrentToken() {
        let coordinator = InsightsActorLoadCoordinator()
        let token = coordinator.begin()
        XCTAssertTrue(coordinator.isCurrent(token))
        coordinator.cancel()
        XCTAssertFalse(coordinator.isCurrent(token))
    }

    func testBeginAfterCancelProducesANewCurrentToken() {
        let coordinator = InsightsActorLoadCoordinator()
        let first = coordinator.begin()
        coordinator.cancel()
        let second = coordinator.begin()
        XCTAssertFalse(coordinator.isCurrent(first))
        XCTAssertTrue(coordinator.isCurrent(second))
        XCTAssertNotEqual(first, second)
    }
}
