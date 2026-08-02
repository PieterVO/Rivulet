// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MenuPressInterceptor.swift
//  Rivulet
//

import UIKit
import os

// MARK: - Handler

/// A surface that wants first refusal on the remote's Menu press.
@MainActor
protocol MenuBackHandling: AnyObject {
    /// Return true to consume the press; false to let it reach the system.
    func handleMenuBack() -> Bool
}

// MARK: - Swallow state

/// Pairs the Menu `.began` we withhold with its matching `.ended`, so the
/// system never sees half a press. Pure logic, kept out of the swizzle so it
/// can be tested directly.
struct MenuPressSwallowState {
    /// The press whose `.began` was withheld, held until its own terminal
    /// phase. Identity rather than a bool, because a bool cannot tell a repeat
    /// `.began` for the SAME press (must not re-ask) from a `.began` for a NEW
    /// one (must be asked).
    ///
    /// That distinction is the whole reason this is not a bool. A consumed
    /// press whose `.ended` never reaches this window — the handler's own
    /// navigation can present or dismiss a controller and route the terminal
    /// phase elsewhere — used to latch the flag on forever. The next real press
    /// was then withheld whole, without any handler being asked and without the
    /// system seeing it, and its `.ended` cleared the latch so the press after
    /// that worked. Every other Menu press did nothing at all, with no way to
    /// recover. Identity makes the stale pending press self-correcting.
    private(set) var isSwallowing = false

    /// Held WEAKLY, and compared by identity rather than by address. An
    /// `ObjectIdentifier` of a freed press can alias a brand new press
    /// allocated at the same address, which would classify it as a repeat and
    /// swallow it — the very bug this tracking exists to prevent. A weak
    /// reference to a freed press reads nil instead, so the new press is
    /// correctly seen as new.
    private weak var pendingPress: AnyObject?

    /// - Parameters:
    ///   - press: identity of the Menu press this event carries, if known. A
    ///     nil identity is always treated as a new press: a missed swallow is
    ///     recoverable, a dead Menu button is not.
    ///   - began: the event carries a Menu press in the `.began` phase.
    ///   - finished: the event carries a Menu press in `.ended` or `.cancelled`.
    ///   - handle: asked once per press, on `.began`. True means consumed.
    /// - Returns: true when this event must be withheld from the system.
    mutating func shouldWithhold(press: AnyObject?,
                                 began: Bool,
                                 finished: Bool,
                                 handle: () -> Bool) -> Bool {
        // The ONLY `.began` that must not re-ask is a repeat of the press
        // already being swallowed. A `.began` for anything else is a new press
        // and gets a fresh decision, which is what stops a pending press that
        // never terminated from eating it.
        let repeatsPendingPress = isSwallowing && press != nil && press === pendingPress
        if began, !repeatsPendingPress {
            let consumed = handle()
            // A single event carrying both phases needs no follow-up swallow.
            isSwallowing = consumed && !finished
            pendingPress = isSwallowing ? press : nil
            return consumed
        }
        guard isSwallowing else { return false }
        if finished {
            isSwallowing = false
            pendingPress = nil
        }
        return true
    }
}

// MARK: - Policy

/// Staged Menu ("back") navigation, stage 1 (issue #19): a Menu press from
/// below the top row returns the page to its top row instead of opening the
/// sidebar.
enum StagedMenuBack {
    /// True when the press should snap the page back to its top row rather than
    /// pass through to the system's sidebar reveal.
    static func shouldReturnToTop(focusedSection: Int?, topSection: Int) -> Bool {
        guard let focusedSection else { return false }
        return focusedSection > topSection
    }
}

// MARK: - Interceptor

/// Gives the app first refusal on the Menu button.
///
/// While focus is in the content area, a Menu press is **not** delivered
/// through the responder chain: there is no `pressesBegan` on the window or the
/// focused view controller, no `shouldUpdateFocus`, no `.onExitCommand`, and no
/// menu-press gesture recognizer anywhere in the hierarchy to intercept — the
/// `.sidebarAdaptable` sidebar reveal happens above all of it. The one layer
/// that sees the press first is `UIWindow.sendEvent(_:)`; returning early there
/// withholds it from the system entirely. (Measured on tvOS 26.5; once focus is
/// in the sidebar the press does reach the responder chain and `.onExitCommand`,
/// which is how stage 3 works — see `TVSidebarView.onExitCommand`.)
@MainActor
enum MenuPressInterceptor {
    private static var swizzledClasses = Set<ObjectIdentifier>()
    private static var handlers: [WeakHandler] = []
    private static var swallowState = MenuPressSwallowState()

    private struct WeakHandler {
        weak var value: (any MenuBackHandling)?
    }

    // MARK: Registration

    static func register(_ handler: any MenuBackHandling) {
        handlers.removeAll { $0.value == nil || $0.value === handler }
        handlers.append(WeakHandler(value: handler))
    }

    /// Drop a surface as it goes away. Only home is a cached controller; every
    /// library, Discover and Search page builds a fresh one, so without this the
    /// list grows by one entry per page visited. A stale entry would still
    /// decline (it checks whether it owns focus), but it would be asked first.
    static func resign(_ handler: any MenuBackHandling) {
        handlers.removeAll { $0.value == nil || $0.value === handler }
    }

    /// Offer the press to registered surfaces, most recently registered first.
    /// Each decides for itself whether it currently owns focus, so a surface
    /// sitting under a presented player or detail page declines.
    private static func offerToHandlers() -> Bool {
        for entry in handlers.reversed() {
            guard let handler = entry.value else { continue }
            if handler.handleMenuBack() { return true }
        }
        return false
    }

    // MARK: Install

    /// Swizzles `sendEvent(_:)` on the window's own class, once per class.
    /// Matches the approach already used for the sidebar focus guard: replacing
    /// on the concrete subclass leaves plain `UIWindow` untouched.
    static func install(in window: UIWindow) {
        let cls: AnyClass = type(of: window)
        guard swizzledClasses.insert(ObjectIdentifier(cls)).inserted else { return }

        let selector = #selector(UIWindow.sendEvent(_:))
        let originalIMP = class_getMethodImplementation(cls, selector)
        typealias OriginalFunc = @convention(c) (AnyObject, Selector, UIEvent) -> Void
        let originalFunc = unsafeBitCast(originalIMP, to: OriginalFunc.self)

        let block: @convention(block) (AnyObject, UIEvent) -> Void = { obj, event in
            guard let pressesEvent = event as? UIPressesEvent else {
                originalFunc(obj, selector, event)
                return
            }
            let withhold = MainActor.assumeIsolated { () -> Bool in
                // This is the only layer that sees a press before a responder or
                // gesture recognizer can consume it, which is exactly what the
                // input probe needs. No-ops unless Input Diagnostics is on.
                InputProbe.record(presses: pressesEvent.allPresses)

                // Withholding drops the whole event, so a non-Menu press
                // batched into the same one goes with it. The remote delivers
                // Menu on its own in practice, and there is no way to forward
                // a partial UIPressesEvent.
                let menuPresses = pressesEvent.allPresses.filter { $0.type == .menu }
                guard !menuPresses.isEmpty else { return false }
                let began = menuPresses.contains { $0.phase == .began }
                let finished = menuPresses.contains { $0.phase == .ended || $0.phase == .cancelled }
                let press = menuPresses.first
                let wasPending = swallowState.isSwallowing
                var asked = false
                let withhold = swallowState.shouldWithhold(
                    press: press,
                    began: began,
                    finished: finished,
                    handle: { asked = true; return offerToHandlers() }
                )
                return withhold
            }
            guard !withhold else { return }
            originalFunc(obj, selector, event)
        }

        let imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
        let method = class_getInstanceMethod(UIWindow.self, selector)!
        class_replaceMethod(cls, selector, imp, method_getTypeEncoding(method)!)
    }
}
