// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InputProbe.swift
//  Rivulet
//
//  Ingress-level input diagnostics (issues #212, #232).
//
//  `PlaybackInputTelemetry` records what an input DID, after a handler claimed
//  it. The third-party-remote bugs are inputs that do NOTHING, which no
//  after-the-fact log can show. This probe records at the ingress instead: every
//  `UIPress` phase the app receives (from the `MenuPressInterceptor` swizzle,
//  the one layer that sees a press before anybody consumes it), every raw
//  GameController event, and the action that eventually resulted.
//
//  Two things it answers that nothing else can:
//
//  1. **Which physical remote class sent this.** `PlaybackInputSource.irPress`
//     only means "arrived as an arrow `UIPress`", which a Siri Remote clickpad
//     edge click also produces — so no existing breadcrumb distinguishes a
//     Harmony from a Siri Remote. A Siri Remote press is always accompanied by a
//     micro-gamepad event; an IR or HDMI-CEC press never is. That is the `gc=`
//     field on each verdict.
//  2. **Whether the press terminated.** Every tap-vs-hold decision in the
//     player reads the began→ended interval against `InputConfig.holdThreshold`.
//     If an IR remote releases late, each tap reads as a hold; if the release
//     never arrives, `UILongPressGestureRecognizer` never reaches a terminal
//     state and `require(toFail:)` blocks every later tap. Both show up here as
//     a duration and a never-terminated warning.
//
//  Off by default, behind Settings → About → Input Diagnostics. Enabled it
//  prints, adds Sentry breadcrumbs, and draws an on-screen HUD so a reporter can
//  send one screenshot.
//

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
        guard isEnabled else { return }
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
            case .ended, .cancelled:
                let cancelled = press.phase == .cancelled
                log("▸ \(name) \(cancelled ? "cancelled" : "ended")")
                if let verdict = tracker.finished(name, at: now, cancelled: cancelled) {
                    log(describe(verdict))
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

    /// Siri Remote state read at the instant a press lands. A clickpad edge
    /// click has `buttonA` down and/or the dpad off-center when its arrow press
    /// arrives; an IR or HDMI-CEC press has no `GCController` behind it at all,
    /// so this returns nil and the verdict reads `gc=no`.
    ///
    /// Polled rather than subscribed because GameController's handlers are
    /// single-slot — installing our own would clobber `RemoteInputHandler`'s and
    /// break seeking. Polling also works on surfaces that have no GameController
    /// wiring of their own (home, settings, detail), which is most of the app.
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
