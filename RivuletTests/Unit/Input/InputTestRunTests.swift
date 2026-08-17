// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InputTestRunTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class InputTestRunTests: XCTestCase {

    private let steps = [
        InputTestStep(prompt: "Press Right", type: "right", wantsHold: false),
        InputTestStep(prompt: "Hold Right for 2 seconds", type: "right", wantsHold: true)
    ]

    private func verdict(
        _ type: String,
        ms: Int,
        hold: Bool,
        gc: Bool = true,
        cancelled: Bool = false
    ) -> InputPressTracker.Verdict {
        InputPressTracker.Verdict(
            type: type,
            duration: TimeInterval(ms) / 1000,
            isHold: hold,
            sawGamepad: gc,
            cancelled: cancelled
        )
    }

    // MARK: Advancing

    func test_matchingVerdict_advancesAndRecords() {
        var run = InputTestRun(steps: steps)
        XCTAssertTrue(run.finished(verdict("right", ms: 118, hold: false)))
        XCTAssertEqual(run.index, 1)
        XCTAssertEqual(run.lines.count, 1)
        XCTAssertTrue(run.lines[0].contains("118ms TAP gc=yes"), run.lines[0])
    }

    func test_wrongType_doesNotAdvance_andIsRecordedAsUnprompted() {
        var run = InputTestRun(steps: steps)
        XCTAssertFalse(run.finished(verdict("left", ms: 90, hold: false)))
        XCTAssertEqual(run.index, 0)
        XCTAssertTrue(run.lines.isEmpty)
        XCTAssertEqual(run.extras.count, 1)
        XCTAssertTrue(run.extras[0].contains("left"), run.extras[0])
    }

    func test_runFinishes_afterEveryStep() {
        var run = InputTestRun(steps: steps)
        run.finished(verdict("right", ms: 100, hold: false))
        run.finished(verdict("right", ms: 2000, hold: true))
        XCTAssertTrue(run.isFinished)
        XCTAssertNil(run.currentStep)
    }

    // MARK: Timeouts — the two failures the issues describe

    /// Issue #305's shape: the button produces no press at all.
    func test_timeoutWithNoPress_recordsNothingReceived() {
        var run = InputTestRun(steps: steps)
        run.timedOut()
        XCTAssertEqual(run.index, 1)
        XCTAssertTrue(run.lines[0].contains("nothing received"), run.lines[0])
    }

    /// Issue #212's shape: the press begins and its release never arrives, which
    /// leaves `require(toFail:)` blocking every later tap.
    func test_timeoutAfterBegan_recordsNeverTerminated() {
        var run = InputTestRun(steps: steps)
        run.began(type: "right")
        run.timedOut()
        XCTAssertTrue(run.lines[0].contains("NEVER TERMINATED"), run.lines[0])
    }

    func test_beganOfAnotherType_doesNotCountAsThisStepBeginning() {
        var run = InputTestRun(steps: steps)
        run.began(type: "left")
        run.timedOut()
        XCTAssertTrue(run.lines[0].contains("nothing received"), run.lines[0])
    }

    func test_beganFlagResets_betweenSteps() {
        var run = InputTestRun(steps: steps)
        run.began(type: "right")
        run.finished(verdict("right", ms: 100, hold: false))
        run.timedOut()
        XCTAssertTrue(run.lines[1].contains("nothing received"), run.lines[1])
    }

    // MARK: Tap/hold mismatch

    func test_holdStepGivenATap_isFlagged() {
        var run = InputTestRun(steps: steps)
        run.finished(verdict("right", ms: 100, hold: false))
        run.finished(verdict("right", ms: 120, hold: false))
        XCTAssertTrue(run.lines[1].contains("asked for a HOLD"), run.lines[1])
    }

    func test_tapStepGivenAHold_isFlagged() {
        var run = InputTestRun(steps: steps)
        run.finished(verdict("right", ms: 900, hold: true))
        XCTAssertTrue(run.lines[0].contains("asked for a TAP"), run.lines[0])
    }

    // MARK: Transcript

    func test_transcript_includesHeaderStepsAndExtras() {
        var run = InputTestRun(steps: steps)
        run.finished(verdict("select", ms: 80, hold: false))
        run.finished(verdict("right", ms: 100, hold: false))
        let text = run.transcript(header: "HEADER")
        XCTAssertTrue(text.hasPrefix("HEADER"))
        XCTAssertTrue(text.contains("Press Right"))
        XCTAssertTrue(text.contains("Unprompted presses:"))
        XCTAssertTrue(text.contains("select"))
    }

    /// A repeating IR code storm must not fill the event with one line per code.
    func test_extras_areCapped() {
        var run = InputTestRun(steps: steps)
        for _ in 0..<60 { run.finished(verdict("left", ms: 40, hold: false)) }
        XCTAssertEqual(run.extras.count, 20)
        XCTAssertTrue(run.transcript(header: "H").contains("more suppressed"))
    }

    func test_noResults_beforeAnyStepCompletes() {
        let run = InputTestRun(steps: steps)
        XCTAssertFalse(run.hasResults)
    }
}
