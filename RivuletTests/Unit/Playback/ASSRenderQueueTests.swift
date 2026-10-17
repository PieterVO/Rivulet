import XCTest
@testable import Rivulet

final class ASSRenderQueueTests: XCTestCase {

    private let step = 40.0
    private let image = LibassRenderer.Output.changed(LibassRenderer.Frame(regions: []))

    /// Starts at `ms`, completes the first frame and the batch after it.
    private func primed(at ms: Double, outputs: (Int) -> LibassRenderer.Output) -> ASSRenderQueue {
        var queue = ASSRenderQueue()
        let first = queue.nextJob(playheadMs: ms, stepMs: step, playing: true)!
        queue.complete(first, outputs: [image])
        let batch = queue.nextJob(playheadMs: ms, stepMs: step, playing: true)!
        queue.complete(batch, outputs: (0..<batch.count).map(outputs))
        return queue
    }

    func test_freshStart_rendersOneForcedFrameCentredOnThePlayhead() {
        var queue = ASSRenderQueue()
        let job = queue.nextJob(playheadMs: 1000, stepMs: step, playing: true)
        XCTAssertEqual(job?.count, 1)
        XCTAssertEqual(job?.force, true)
        XCTAssertEqual(job?.sampleMs(0), 1000)
    }

    func test_whilePlaying_keepsHalfASecondAhead() {
        var queue = ASSRenderQueue()
        let first = queue.nextJob(playheadMs: 1000, stepMs: step, playing: true)!
        let batch = queue.nextJob(playheadMs: 1000, stepMs: step, playing: true)
        XCTAssertEqual(batch?.fromMs, first.endMs, "the batch chains onto the frame still in flight")
        XCTAssertEqual(batch?.force, false)
        XCTAssertGreaterThanOrEqual(batch!.endMs, 1000 + ASSRenderQueue.aheadMs)
        XCTAssertNil(queue.nextJob(playheadMs: 1000, stepMs: step, playing: true), "two jobs in flight at most")
    }

    func test_unchangedFrames_extendOneUnit() {
        let queue = primed(at: 1000) { _ in .unchanged }
        XCTAssertEqual(queue.units.count, 1)
        XCTAssertGreaterThanOrEqual(queue.units[0].end, 1500)
        XCTAssertEqual(queue.unit(at: 1400)?.id, queue.unit(at: 1000)?.id)
    }

    func test_changedFrames_getOneUnitEach() {
        let queue = primed(at: 1000) { _ in self.image }
        XCTAssertGreaterThan(queue.units.count, 10)
        XCTAssertNotEqual(queue.unit(at: 1000)?.id, queue.unit(at: 1000 + step)?.id)
    }

    func test_noRefillUntilBelowLowWater() {
        var queue = primed(at: 1000) { _ in .unchanged }
        XCTAssertNil(queue.nextJob(playheadMs: 1100, stepMs: step, playing: true))
        XCTAssertNotNil(queue.nextJob(playheadMs: 1300, stepMs: step, playing: true))
    }

    func test_paused_rendersThePlayheadOnceAndNothingAhead() {
        var queue = ASSRenderQueue()
        let job = queue.nextJob(playheadMs: 1000, stepMs: step, playing: false)!
        XCTAssertEqual(job.count, 1)
        queue.complete(job, outputs: [image])
        XCTAssertNil(queue.nextJob(playheadMs: 1000, stepMs: step, playing: false))
    }

    /// Device regression: the seek frame landed before the next tick, the
    /// playhead was already past it, and every tick reset into another single
    /// frame, so nothing showed for seconds.
    func test_seekFrameLandsBeforeNextTick_continuesInsteadOfResetting() {
        var queue = ASSRenderQueue()
        let first = queue.nextJob(playheadMs: 1000, stepMs: step, playing: true)!
        queue.complete(first, outputs: [image])
        let generation = queue.generation
        let batch = queue.nextJob(playheadMs: 1000 + step, stepMs: step, playing: true)!
        XCTAssertEqual(queue.generation, generation, "no reset")
        XCTAssertGreaterThan(batch.count, 1)
        XCTAssertLessThanOrEqual(batch.fromMs, 1000 + step)
        queue.complete(batch, outputs: (0..<batch.count).map { _ in image })
        XCTAssertNotNil(queue.unit(at: 1000 + step))
    }

    func test_seekBackward_resetsToThePlayhead() {
        var queue = primed(at: 10_000) { _ in .unchanged }
        let generation = queue.generation
        let job = queue.nextJob(playheadMs: 2000, stepMs: step, playing: true)
        XCTAssertEqual(job?.sampleMs(0), 2000)
        XCTAssertEqual(job?.force, true)
        XCTAssertTrue(queue.units.isEmpty)
        XCTAssertGreaterThan(queue.generation, generation)
    }

    func test_seekForwardPastTheQueue_resets() {
        var queue = primed(at: 1000) { _ in .unchanged }
        let job = queue.nextJob(playheadMs: 60_000, stepMs: step, playing: true)
        XCTAssertEqual(job?.sampleMs(0), 60_000)
        XCTAssertEqual(job?.count, 1)
    }

    func test_playheadInsideAFrameInFlight_waits() {
        var queue = ASSRenderQueue()
        _ = queue.nextJob(playheadMs: 1000, stepMs: step, playing: false)
        XCTAssertNil(queue.nextJob(playheadMs: 1000, stepMs: step, playing: false))
    }

    func test_staleJob_isDropped() {
        var queue = ASSRenderQueue()
        let job = queue.nextJob(playheadMs: 1000, stepMs: step, playing: true)!
        queue.reset()
        queue.complete(job, outputs: [image])
        XCTAssertTrue(queue.units.isEmpty)
    }

    func test_eventInsideRenderedWindow_truncatesAndForcesTheNextFrame() {
        var queue = primed(at: 1000) { _ in .unchanged }
        queue.eventsAdded([1200..<3000])
        XCTAssertEqual(queue.units.last?.end, 1200)
        let job = queue.nextJob(playheadMs: 1000, stepMs: step, playing: true)
        XCTAssertEqual(job?.fromMs, 1200)
        XCTAssertEqual(job?.force, true)
    }

    func test_eventAtThePlayhead_rerendersThePlayhead() {
        var queue = primed(at: 1000) { _ in .unchanged }
        queue.eventsAdded([900..<3000])
        let job = queue.nextJob(playheadMs: 1000, stepMs: step, playing: true)
        XCTAssertEqual(job?.sampleMs(0), 1000)
        XCTAssertEqual(job?.force, true)
    }

    func test_eventsOutsideRenderedWindow_changeNothing() {
        var queue = primed(at: 1000) { _ in .unchanged }
        let units = queue.units.count, generation = queue.generation
        queue.eventsAdded([0..<500, 60_000..<61_000])
        XCTAssertEqual(queue.units.count, units)
        XCTAssertEqual(queue.generation, generation)
    }

    func test_playedUnitsArePrunedButTheLastStays() {
        var queue = primed(at: 1000) { _ in self.image }
        _ = queue.nextJob(playheadMs: 1300, stepMs: step, playing: true)
        XCTAssertTrue(queue.units.allSatisfy { $0.end > 1300 })
        XCTAssertNotNil(queue.unit(at: 1300))
    }
}
