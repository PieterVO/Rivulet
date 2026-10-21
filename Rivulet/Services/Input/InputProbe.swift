// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Ingress input diagnostics (#212, #232): logs every UIPress phase and GameController event.
// A Siri Remote press always comes with a micro-gamepad event and an IR/CEC press never does (`gc=`).
// Also reports presses that never terminate, which block every later `require(toFail:)` tap.
// Off by default: Settings > About > Input Diagnostics.

import UIKit
import GameController
import Sentry

// MARK: - Press tracking (pure)

/// Pairs each press's `began` with its terminal phase so the probe can report a
/// duration, a tap-vs-hold verdict, and whether a GameController event
/// accompanied the press. Kept out of the `@MainActor` probe so it is testable
/// without a window or a remote.
struct InputPressTracker {
    struct Verdict {
        let type: String
        let duration: TimeInterval
        let isHold: Bool
        let sawGamepad: Bool
        let cancelled: Bool
    }

    /// A press still open past this is reported as never terminated — the exact
    /// failure the IR hypothesis predicts.
    static let staleAfter: TimeInterval = 3.0

    private struct Open {
        let at: TimeInterval
        var sawGamepad: Bool
    }

    private let holdThreshold: TimeInterval
    private var open: [String: Open] = [:]

    init(holdThreshold: TimeInterval = InputConfig.holdThreshold) {
        self.holdThreshold = holdThreshold
    }

    var openCount: Int { open.count }

    /// Returns a warning when a press of this type was already open, meaning the
    /// previous one never reached `ended` or `cancelled`.
    mutating func began(_ type: String, at now: TimeInterval) -> String? {
        let orphan = open[type].map {
            "\(type) re-began with the previous press still open after \(Self.ms(now - $0.at))"
        }
        open[type] = Open(at: now, sawGamepad: false)
        return orphan
    }

    /// Flags every open press as having seen a controller event. Correlating by
    /// time window rather than by press identity is deliberate: the question is
    /// only whether the physical remote drives GameController at all.
    mutating func gamepadEvent() {
        for key in open.keys { open[key]?.sawGamepad = true }
    }

    mutating func finished(_ type: String, at now: TimeInterval, cancelled: Bool) -> Verdict? {
        guard let press = open.removeValue(forKey: type) else { return nil }
        let duration = now - press.at
        return Verdict(
            type: type,
            duration: duration,
            isHold: duration >= holdThreshold,
            sawGamepad: press.sawGamepad,
            cancelled: cancelled
        )
    }

    /// Drops and reports presses that never terminated.
    // ponytail: swept on the next event rather than from a timer, so a press
    // that never ends and is never followed by any other input goes unreported.
    // Add a watchdog timer only if that case turns out to matter in the field.
    mutating func sweepStale(now: TimeInterval) -> [String] {
        let stale = open.filter { now - $0.value.at > Self.staleAfter }
        for key in stale.keys { open.removeValue(forKey: key) }
        return stale
            .map { "\($0.key) never terminated (open \(Self.ms(now - $0.value.at)))" }
            .sorted()
    }

    static func ms(_ interval: TimeInterval) -> String { "\(Int(interval * 1000))ms" }
}

// MARK: - Probe

@MainActor
enum InputProbe {
    static let settingsKey = "inputProbeEnabled"

    private static let maxLines = 16

    private(set) static var isEnabled = SettingsStore.bool(settingsKey, default: false)

    private static var tracker = InputPressTracker()
    private static var lines: [String] = []
    private static var lastEventAt: TimeInterval?
    private static weak var hud: InputProbeHUDView?

    /// What an observer is told. `began` exists so a caller can tell "nothing
    /// arrived" from "it began and never terminated" without waiting for
    /// `sweepStale`, which only runs on the NEXT event and so never fires when
    /// the stuck press is the last input the app sees.
    enum ProbeEvent {
        case began(type: String)
        case finished(InputPressTracker.Verdict)
    }

    /// Set while the guided input test is on screen. Ingress recording runs for
    /// an observer whether or not the user has the diagnostics toggle on — the
    /// test is the supported way to get this data, so it must not need a second
    /// switch flipped first.
    private(set) static var observer: ((ProbeEvent) -> Void)?

    static func beginObserving(_ block: @escaping (ProbeEvent) -> Void) {
        tracker = InputPressTracker()
        observer = block
        // The HUD is window-level and re-fronts itself on every event, so it
        // would sit on top of the test's own prompt.
        hud?.isHidden = true
    }

    static func endObserving() {
        observer = nil
        hud?.isHidden = false
    }

    static func setEnabled(_ on: Bool) {
        SettingsStore.setBool(settingsKey, on)
        isEnabled = on
        guard on else {
            hud?.removeFromSuperview()
            hud = nil
            return
        }
        tracker = InputPressTracker()
        lines.removeAll()
        lastEventAt = nil
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        log("probe on (build \(build)) — hold threshold \(InputPressTracker.ms(InputConfig.holdThreshold))")
    }

    // MARK: Ingress

    /// Every press the app receives, in every phase, before any responder or
    /// gesture recognizer has had a chance to consume it. Called from the
    /// `MenuPressInterceptor` `sendEvent` swizzle.
    static func record(presses: Set<UIPress>) {
        guard isEnabled || observer != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for warning in tracker.sweepStale(now: now) { log("⚠︎ \(warning)") }

        // Ordered by phase so a began and its terminal phase batched into one
        // event are tracked in the right order.
        for press in presses.sorted(by: { $0.phase.rawValue < $1.phase.rawValue }) {
            let name = pressName(press.type)
            switch press.phase {
            case .began:
                if let orphan = tracker.began(name, at: now) { log("⚠︎ \(orphan)") }
                let responder = press.responder.map { String(describing: type(of: $0)) } ?? "none"
                log("▸ \(name) began  resp=\(responder) key=\(press.key != nil ? "yes" : "no")")
                if let state = microGamepadState() {
                    tracker.gamepadEvent()
                    log("● gc \(state)")
                }
                observer?(.began(type: name))
            case .ended, .cancelled:
                let cancelled = press.phase == .cancelled
                log("▸ \(name) \(cancelled ? "cancelled" : "ended")")
                if let verdict = tracker.finished(name, at: now, cancelled: cancelled) {
                    log(describe(verdict))
                    observer?(.finished(verdict))
                }
            default:
                break
            }
        }
    }

    /// A raw GameController event, logged before any gating. Called from
    /// `RemoteInputHandler`, so it covers the player surfaces precisely; the
    /// press-time poll below covers everywhere else.
    static func gamepad(_ what: String) {
        guard isEnabled else { return }
        tracker.gamepadEvent()
        log("● gc \(what)")
    }

    /// Siri Remote state when a press lands; nil for IR/CEC (`gc=no`). Polled because
    /// GameController handlers are single-slot: our own would replace `RemoteInputHandler`'s.
    private static func microGamepadState() -> String? {
        guard let micro = GCController.controllers().lazy.compactMap(\.microGamepad).first else {
            return nil
        }
        let x = micro.dpad.xAxis.value
        let y = micro.dpad.yAxis.value
        let clicked = micro.buttonA.isPressed
        guard clicked || abs(x) > 0.1 || abs(y) > 0.1 else { return nil }
        return String(format: "micro click=%@ dpad=%.2f,%.2f", clicked ? "yes" : "no", x, y)
    }

    /// The action a press eventually produced. Absence of one of these after a
    /// press is the "nothing happened" both issues report.
    static func action(_ action: String, source: String) {
        guard isEnabled else { return }
        log("→ \(action) via \(source)")
    }

    // MARK: Reporting

    /// Ships one finished input test as its own Sentry event, grouped by a fixed fingerprint.
    /// Not breadcrumbs: those leave the device only attached to some other event.
    static func captureTestResult(_ transcript: String) {
        let event = Sentry.Event(level: .info)
        event.message = SentryMessage(formatted: "Remote input test")
        event.fingerprint = ["rivulet-input-test"]
        event.tags = ["input_test": "1"]
        event.extra = ["transcript": transcript]
        SentryBridge.capture(event: event)
    }

    // MARK: Formatting

    private static func describe(_ verdict: InputPressTracker.Verdict) -> String {
        var line = "✓ \(verdict.type) \(InputPressTracker.ms(verdict.duration)) "
        line += verdict.isHold ? "HOLD" : "TAP"
        line += " gc=\(verdict.sawGamepad ? "yes" : "no")"
        if verdict.cancelled { line += " (cancelled)" }
        return line
    }

    private static func pressName(_ type: UIPress.PressType) -> String {
        switch type {
        case .upArrow: return "up"
        case .downArrow: return "down"
        case .leftArrow: return "left"
        case .rightArrow: return "right"
        case .select: return "select"
        case .menu: return "menu"
        case .playPause: return "playPause"
        case .pageUp: return "pageUp"
        case .pageDown: return "pageDown"
        @unknown default: return "raw(\(type.rawValue))"
        }
    }

    private static func log(_ text: String) {
        // Observer-only mode (the guided test with the toggle off) records
        // ingress but must not print, breadcrumb, or draw the HUD.
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = "+\(Int((now - (lastEventAt ?? now)) * 1000))ms"
        lastEventAt = now
        let pad = String(repeating: " ", count: max(0, 8 - delta.count))

        print("🎛️ [INPUT] \(pad)\(delta) \(text)")

        let crumb = Breadcrumb(level: .info, category: "input_probe")
        crumb.message = text
        SentryBridge.addBreadcrumb(crumb)

        lines.append("\(pad)\(delta)  \(text)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }

        // Deferred: `record(presses:)` runs inside `UIWindow.sendEvent`, and
        // mutating the view hierarchy mid-dispatch is not worth the risk. The
        // HUD renders the whole buffer, so a late render loses no ordering.
        DispatchQueue.main.async { renderHUD() }
    }

    private static func renderHUD() {
        guard isEnabled else { return }
        let view: InputProbeHUDView
        if let existing = hud, let window = existing.window {
            // A presented player or popup adds its transition view as a sibling
            // above ours, so re-front on every render. `zPosition` alone orders
            // the render pass but is easy to lose to a later hierarchy change,
            // and a HUD hidden behind the player is a useless diagnostic.
            window.bringSubviewToFront(existing)
            view = existing
        } else {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) })
                .first
            else { return }  // no window yet; the next event retries
            view = InputProbeHUDView()
            window.addSubview(view)
            let guide = window.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: guide.topAnchor),
                view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                view.widthAnchor.constraint(equalToConstant: 1100)
            ])
            hud = view
        }
        view.setLines(lines)
    }
}

// MARK: - HUD

/// Non-focusable, non-interactive overlay pinned to the key window so it
/// survives view-controller transitions and can never take focus.
private final class InputProbeHUDView: UIView {
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.75)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.zPosition = 10_000

        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 20, weight: .regular)
        label.textColor = .white
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLines(_ lines: [String]) {
        label.text = lines.joined(separator: "\n")
    }
}
