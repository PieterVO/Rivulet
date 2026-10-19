// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class HeroBackdropScrollTests: XCTestCase {
    private let height: CGFloat = 1080, shelfTop: CGFloat = 920

    func test_rest_noLiftFullShowcase() {
        XCTAssertEqual(HeroBackdropView.scrollLift(0, shelfTop: shelfTop, height: height), 0)
        XCTAssertEqual(HeroBackdropView.scrollLift(-50, shelfTop: shelfTop, height: height), 0)
        XCTAssertEqual(HeroBackdropView.showcasePercentage(0, shelfTop: shelfTop), 1)
    }

    /// Apple's catch-up: the backdrop's bottom edge meets the first shelf at
    /// y 338, then both move together.
    func test_backdropBottomMeetsShelf_thenRidesContent() {
        let travel = shelfTop - HeroBackdropView.meetY
        let lift = HeroBackdropView.scrollLift(travel, shelfTop: shelfTop, height: height)
        XCTAssertEqual(height - lift, shelfTop - travel)
        XCTAssertEqual(HeroBackdropView.showcasePercentage(travel, shelfTop: shelfTop), 0)
        let later = HeroBackdropView.scrollLift(travel + 100, shelfTop: shelfTop, height: height)
        XCTAssertEqual(later - lift, 100)
    }

    /// Apple's layout (shelf at 793) gives its read 1.63x rate.
    func test_appleConstants_rate() {
        let rate = HeroBackdropView.scrollLift(100, shelfTop: 793, height: 1080) / 100
        XCTAssertEqual(rate, 1 + 287.0 / 455.0, accuracy: 0.001)
    }
}
