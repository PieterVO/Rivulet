//
//  PlaybackInputCoordinator.swift
//  Rivulet
//
//  Deduplicates and coalesces input events before dispatching to a playback target.
//

import Foundation

final class PlaybackInputCoordinator {
    @MainActor weak var target: PlaybackInputTarget?

    private var lastAction: PlaybackInputAction?
    private var lastActionSource: PlaybackInputSource = .unknown
    private var lastActionAt = Date.distantPast

    private var pendingSeekSeconds: TimeInterval = 0
    private var pendingSeekSource: PlaybackInputSource = .unknown
    private var seekCoalesceTimer: Timer?

    deinit {
        seekCoalesceTimer?.invalidate()
    }

    @MainActor
    func handle(action: PlaybackInputAction, source: PlaybackInputSource) {
        guard let target else { return }
        PlaybackInputTelemetry.shared.recordReceived(
            action: action,
            source: source,
            isScrubbing: target.isScrubbingForInput
        )

        switch action {
        case .stepSeek(let forward):
            let delta = forward ? InputConfig.tapSeekSeconds : -InputConfig.tapSeekSeconds
            handleRelativeSeek(delta, source: source, target: target)

        case .jumpSeek(let forward):
            let delta = forward ? InputConfig.jumpSeekSeconds : -InputConfig.jumpSeekSeconds
            handleRelativeSeek(delta, source: source, target: target)

        default:
            flushPendingSeekIfNeeded()
            dispatch(action: action, source: source, target: target)
        }
    }

    @MainActor
    func invalidate() {
        PlaybackInputTelemetry.shared.flushSessionSummary(reason: "coordinator_invalidate")
        seekCoalesceTimer?.invalidate()
        seekCoalesceTimer = nil
        pendingSeekSeconds = 0
        lastAction = nil
        lastActionSource = .unknown
        lastActionAt = .distantPast
        target = nil
    }

    @MainActor
    private func handleRelativeSeek(_ delta: TimeInterval, source: PlaybackInputSource, target: PlaybackInputTarget) {
        let canonical = PlaybackInputAction.seekRelative(seconds: delta)
        if isDuplicate(canonical, source: source, crossSourceOnly: true) {
            PlaybackInputTelemetry.shared.recordDeduped(
                action: canonical,
                source: source,
                window: InputConfig.actionDedupeWindow,
                crossSourceOnly: true
            )
            return
        }
        recordDispatchedAction(canonical, source: source)

        if target.isScrubbingForInput {
            target.handleInputAction(canonical, source: source)
            return
        }

        pendingSeekSeconds += delta
        pendingSeekSource = source

        seekCoalesceTimer?.invalidate()
        seekCoalesceTimer = Timer.scheduledTimer(withTimeInterval: InputConfig.seekCoalesceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushPendingSeekIfNeeded()
            }
        }
    }

    @MainActor
    private func flushPendingSeekIfNeeded() {
        guard pendingSeekSeconds != 0 else { return }
        guard let target else {
            pendingSeekSeconds = 0
            return
        }

        let seconds = pendingSeekSeconds
        pendingSeekSeconds = 0
        seekCoalesceTimer?.invalidate()
        seekCoalesceTimer = nil

        target.handleInputAction(.seekRelative(seconds: seconds), source: pendingSeekSource)
        PlaybackInputTelemetry.shared.recordCoalescedSeek(totalSeconds: seconds, source: pendingSeekSource)
    }

    @MainActor
    private func dispatch(action: PlaybackInputAction, source: PlaybackInputSource, target: PlaybackInputTarget) {
        if shouldDedupe(action), isDuplicate(action, source: source) {
            PlaybackInputTelemetry.shared.recordDeduped(
                action: action,
                source: source,
                window: InputConfig.actionDedupeWindow,
                crossSourceOnly: false
            )
            return
        }

        recordDispatchedAction(action, source: source)
        target.handleInputAction(action, source: source)
    }

    @MainActor
    private func shouldDedupe(_ action: PlaybackInputAction) -> Bool {
        switch action {
        case .seekAbsolute, .scrubRelative:
            return false
        default:
            return true
        }
    }

    @MainActor
    private func isDuplicate(
        _ action: PlaybackInputAction,
        source: PlaybackInputSource,
        crossSourceOnly: Bool = false
    ) -> Bool {
        guard lastAction == action else { return false }
        if crossSourceOnly, lastActionSource == source { return false }
        return Date().timeIntervalSince(lastActionAt) < InputConfig.actionDedupeWindow
    }

    @MainActor
    private func recordDispatchedAction(_ action: PlaybackInputAction, source: PlaybackInputSource) {
        lastAction = action
        lastActionSource = source
        lastActionAt = Date()
    }
}
