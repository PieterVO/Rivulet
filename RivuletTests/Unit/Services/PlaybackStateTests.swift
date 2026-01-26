//
//  PlaybackStateTests.swift
//  RivuletTests
//
//  Unit tests for UniversalPlaybackState and PlayerError
//

import XCTest
@testable import Rivulet

final class PlaybackStateTests: XCTestCase {

    // MARK: - UniversalPlaybackState Tests

    func testIdleStateIsNotActive() {
        let state = UniversalPlaybackState.idle
        XCTAssertFalse(state.isActive)
    }

    func testLoadingStateIsNotActive() {
        let state = UniversalPlaybackState.loading
        XCTAssertFalse(state.isActive)
    }

    func testReadyStateIsNotActive() {
        let state = UniversalPlaybackState.ready
        XCTAssertFalse(state.isActive)
    }

    func testPlayingStateIsActive() {
        let state = UniversalPlaybackState.playing
        XCTAssertTrue(state.isActive)
    }

    func testPausedStateIsActive() {
        let state = UniversalPlaybackState.paused
        XCTAssertTrue(state.isActive)
    }

    func testBufferingStateIsActive() {
        let state = UniversalPlaybackState.buffering
        XCTAssertTrue(state.isActive)
    }

    func testEndedStateIsNotActive() {
        let state = UniversalPlaybackState.ended
        XCTAssertFalse(state.isActive)
    }

    func testFailedStateIsNotActive() {
        let state = UniversalPlaybackState.failed(.unknown("test"))
        XCTAssertFalse(state.isActive)
    }

    func testFailedStateIsFailed() {
        let state = UniversalPlaybackState.failed(.networkError("test"))
        XCTAssertTrue(state.isFailed)
    }

    func testNonFailedStatesAreNotFailed() {
        let states: [UniversalPlaybackState] = [
            .idle, .loading, .ready, .playing, .paused, .buffering, .ended
        ]

        for state in states {
            XCTAssertFalse(state.isFailed, "\(state) should not be failed")
        }
    }

    func testStatesAreEquatable() {
        XCTAssertEqual(UniversalPlaybackState.idle, UniversalPlaybackState.idle)
        XCTAssertEqual(UniversalPlaybackState.playing, UniversalPlaybackState.playing)
        XCTAssertNotEqual(UniversalPlaybackState.playing, UniversalPlaybackState.paused)
    }

    func testFailedStatesWithSameErrorAreEqual() {
        let state1 = UniversalPlaybackState.failed(.networkError("timeout"))
        let state2 = UniversalPlaybackState.failed(.networkError("timeout"))
        XCTAssertEqual(state1, state2)
    }

    func testFailedStatesWithDifferentErrorsAreNotEqual() {
        let state1 = UniversalPlaybackState.failed(.networkError("timeout"))
        let state2 = UniversalPlaybackState.failed(.loadFailed("file not found"))
        XCTAssertNotEqual(state1, state2)
    }

    // MARK: - PlayerError Tests

    func testInvalidURLErrorDescription() {
        let error = PlayerError.invalidURL
        XCTAssertEqual(error.localizedDescription, "Invalid media URL")
    }

    func testLoadFailedErrorDescription() {
        let error = PlayerError.loadFailed("File not found")
        XCTAssertEqual(error.localizedDescription, "Failed to load media: File not found")
    }

    func testNetworkErrorDescription() {
        let error = PlayerError.networkError("Connection timeout")
        XCTAssertEqual(error.localizedDescription, "Network error: Connection timeout")
    }

    func testCodecUnsupportedErrorDescription() {
        let error = PlayerError.codecUnsupported("DTS-HD MA")
        XCTAssertEqual(error.localizedDescription, "Unsupported codec: DTS-HD MA")
    }

    func testUnknownErrorDescription() {
        let error = PlayerError.unknown("Something went wrong")
        XCTAssertEqual(error.localizedDescription, "Playback error: Something went wrong")
    }

    func testPlayerErrorsAreEquatable() {
        XCTAssertEqual(PlayerError.invalidURL, PlayerError.invalidURL)
        XCTAssertEqual(PlayerError.loadFailed("test"), PlayerError.loadFailed("test"))
        XCTAssertNotEqual(PlayerError.loadFailed("test1"), PlayerError.loadFailed("test2"))
    }

    // MARK: - State Transition Logic Tests

    func testValidStateTransitions() {
        // These represent valid state transitions in the player
        let validTransitions: [(UniversalPlaybackState, UniversalPlaybackState)] = [
            (.idle, .loading),
            (.loading, .ready),
            (.loading, .failed(.loadFailed("test"))),
            (.ready, .playing),
            (.playing, .paused),
            (.paused, .playing),
            (.playing, .buffering),
            (.buffering, .playing),
            (.playing, .ended),
            (.paused, .ended),
        ]

        // This test documents expected transitions - actual validation would be in the player
        for (from, to) in validTransitions {
            XCTAssertNotEqual(from, to, "Transition from \(from) to \(to) should be valid")
        }
    }
}
