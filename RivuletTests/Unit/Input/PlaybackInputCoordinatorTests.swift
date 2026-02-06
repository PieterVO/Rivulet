//
//  PlaybackInputCoordinatorTests.swift
//  RivuletTests
//
//  Unit tests for deduplication and coalescing behavior in PlaybackInputCoordinator.
//

import XCTest
@testable import Rivulet

@MainActor
final class PlaybackInputCoordinatorTests: XCTestCase {

    private final class MockTarget: PlaybackInputTarget {
        var isScrubbingForInput = false
        private(set) var received: [(PlaybackInputAction, PlaybackInputSource)] = []

        func handleInputAction(_ action: PlaybackInputAction, source: PlaybackInputSource) {
            received.append((action, source))
        }
    }

    private func waitForCoalesceWindow() {
        let until = Date().addingTimeInterval(InputConfig.seekCoalesceInterval + 0.08)
        RunLoop.main.run(until: until)
    }

    func testRapidStepSeeksAreCoalescedIntoSingleRelativeSeek() {
        let coordinator = PlaybackInputCoordinator()
        let target = MockTarget()
        coordinator.target = target

        coordinator.handle(action: .stepSeek(forward: true), source: .siriMicroGamepad)
        coordinator.handle(action: .stepSeek(forward: true), source: .siriMicroGamepad)
        coordinator.handle(action: .stepSeek(forward: false), source: .siriMicroGamepad)

        waitForCoalesceWindow()

        XCTAssertEqual(target.received.count, 1)
        guard case .seekRelative(let seconds) = target.received[0].0 else {
            return XCTFail("Expected coalesced seekRelative action")
        }
        XCTAssertEqual(seconds, InputConfig.tapSeekSeconds, accuracy: 0.0001)
    }

    func testDuplicateRelativeSeekFromDifferentSourcesIsDeduped() {
        let coordinator = PlaybackInputCoordinator()
        let target = MockTarget()
        coordinator.target = target

        coordinator.handle(action: .stepSeek(forward: true), source: .siriMicroGamepad)
        coordinator.handle(action: .stepSeek(forward: true), source: .irPress)

        waitForCoalesceWindow()

        XCTAssertEqual(target.received.count, 1)
        guard case .seekRelative(let seconds) = target.received[0].0 else {
            return XCTFail("Expected seekRelative action")
        }
        XCTAssertEqual(seconds, InputConfig.tapSeekSeconds, accuracy: 0.0001)
    }

    func testScrubNudgeIsDispatchedImmediatelyWithoutCoalescing() {
        let coordinator = PlaybackInputCoordinator()
        let target = MockTarget()
        coordinator.target = target

        coordinator.handle(action: .scrubNudge(forward: true), source: .keyboard)

        XCTAssertEqual(target.received.count, 1)
        XCTAssertEqual(target.received[0].0, .scrubNudge(forward: true))
        XCTAssertEqual(target.received[0].1, .keyboard)
    }

    func testSeekWhileScrubbingBypassesCoalescing() {
        let coordinator = PlaybackInputCoordinator()
        let target = MockTarget()
        target.isScrubbingForInput = true
        coordinator.target = target

        coordinator.handle(action: .stepSeek(forward: true), source: .extendedGamepad)

        XCTAssertEqual(target.received.count, 1)
        guard case .seekRelative(let seconds) = target.received[0].0 else {
            return XCTFail("Expected immediate seekRelative while scrubbing")
        }
        XCTAssertEqual(seconds, InputConfig.tapSeekSeconds, accuracy: 0.0001)
    }
}
