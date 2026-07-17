// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInfoTabsAvailabilityTests.swift
//  RivuletTests
//
//  The Info popup shows its Info | Advanced tab bar only on the aether route
//  (a non-nil advanced-stats provider). On the hls route it renders just the
//  Info sheet, exactly as before.
//

import XCTest
@testable import Rivulet

@MainActor
final class PlayerInfoTabsAvailabilityTests: XCTestCase {

    func testTabBarShownWhenAdvancedProviderPresent() {
        let provider: (() -> AetherAdvancedStats?)? = { AetherAdvancedStats(backend: "VideoToolbox HEVC (HW)") }
        XCTAssertTrue(PlayerInfoTabsView.showsTabBar(advancedProvider: provider))
    }

    func testTabBarHiddenWhenNoAdvancedProvider() {
        XCTAssertFalse(PlayerInfoTabsView.showsTabBar(advancedProvider: nil))
    }
}
