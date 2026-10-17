// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ASSRenderQueue.swift
//  Rivulet
//
//  The render-ahead schedule for libass. Units are rendered ahead of the
//  playhead, one per display frame while libass reports a change; an unchanged
//  frame extends the previous unit instead. The display tick only picks the
//  unit covering the time on screen. Pure, so the timing is testable.
//

import Foundation

/// A batch of renders: `count` frames `stepMs` apart, each sampled at the
/// middle of its unit. `force` makes the first one produce an image even when
/// libass sees no change (its last render was elsewhere).
nonisolated struct ASSRenderJob: Equatable, Sendable {
    let fromMs: Double
    let stepMs: Double
    let count: Int
    let force: Bool
    let generation: Int

    func sampleMs(_ index: Int) -> Int64 { Int64((fromMs + (Double(index) + 0.5) * stepMs).rounded()) }
    var endMs: Double { fromMs + Double(count) * stepMs }
}

nonisolated struct ASSRenderQueue {

    struct Unit {
        let id: Int
        let start: Double
        var end: Double
        let frame: LibassRenderer.Frame?
    }

    static var aheadMs: Double { 500 }
    static var lowWaterMs: Double { 250 }
    static var maxJobCount: Int { 60 }

    private(set) var units: [Unit] = []
    private(set) var pending: [ASSRenderJob] = []
    private(set) var generation = 0
    private var needsForce = true
    private var nextID = 0

    func unit(at ms: Double) -> Unit? { units.first { $0.start <= ms && ms < $0.end } }

    /// Drops everything, including jobs in flight.
    mutating func reset() {
        units.removeAll()
        pending.removeAll()
        generation += 1
        needsForce = true
    }

    /// New events reached libass. Whatever was rendered from the earliest one
    /// that is still live in the rendered window is stale.
    mutating func eventsAdded(_ spans: [Range<Double>]) {
        guard let lo = units.first?.start ?? pending.first?.fromMs else { return }
        let hi = pending.last?.endMs ?? units.last?.end ?? lo
        guard let from = spans.filter({ $0.upperBound > lo }).map(\.lowerBound).min(), from < hi else { return }
        units.removeAll { $0.start >= from }
        if let last = units.indices.last, units[last].end > from { units[last].end = from }
        pending.removeAll()
        generation += 1
        needsForce = true
    }

    /// The job to start for this playhead, or nil. Paused (`playing` false)
    /// renders the playhead once; playing keeps `aheadMs` rendered.
    mutating func nextJob(playheadMs p: Double, stepMs: Double, playing: Bool) -> ASSRenderJob? {
        // The last unit stays: an unchanged render extends it.
        while units.count > 1, units[0].end <= p { units.removeFirst() }
        let lo = units.first?.start ?? pending.first?.fromMs
        let hi = pending.last?.endMs ?? units.last?.end ?? -.infinity
        // A seek: one frame at the playhead first, so the picture is right as
        // soon as possible.
        guard let lo, lo <= p, p < hi + Self.aheadMs else {
            reset()
            return start(fromMs: p - stepMs / 2, stepMs: stepMs, count: 1)
        }
        guard playing, pending.count < 2, hi - p < Self.lowWaterMs else { return nil }
        // Fell a little behind (or the seek frame just landed): render on from
        // the playhead instead of frames already shown.
        let from = max(hi, p - stepMs / 2)
        let count = Int(((p + Self.aheadMs - from) / stepMs).rounded(.up))
        return start(fromMs: from, stepMs: stepMs, count: min(max(count, 1), Self.maxJobCount))
    }

    /// Takes a job's renders. A job from before a reset or invalidation is dropped.
    mutating func complete(_ job: ASSRenderJob, outputs: [LibassRenderer.Output]) {
        guard job.generation == generation, let index = pending.firstIndex(of: job) else { return }
        pending.remove(at: index)
        // Out of order would misplace units; drop it and let the gap re-render.
        guard index == 0 else { return }
        for (offset, output) in outputs.enumerated() {
            let start = job.fromMs + Double(offset) * job.stepMs
            switch output {
            case .unchanged:
                guard let last = units.indices.last else { continue }
                units[last].end = start + job.stepMs
            case .changed(let frame):
                nextID += 1
                units.append(Unit(id: nextID, start: start, end: start + job.stepMs, frame: frame))
            }
        }
    }

    private mutating func start(fromMs: Double, stepMs: Double, count: Int) -> ASSRenderJob {
        let job = ASSRenderJob(fromMs: fromMs, stepMs: stepMs, count: count,
                               force: needsForce, generation: generation)
        needsForce = false
        pending.append(job)
        return job
    }
}
