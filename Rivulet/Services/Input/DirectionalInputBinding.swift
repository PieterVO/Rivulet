// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DirectionalInputBinding.swift
//  Rivulet
//
//  One call gives a FOCUSLESS surface every remote transport for directional
//  input.
//
//  tvOS delivers directional input on two disjoint paths: d-pad clicks,
//  clickpad-edge clicks, IR/CEC remotes, and keyboard arrows arrive as
//  discrete arrow `UIPress`es, while Siri Remote and iPhone-Remote
//  touch-surface swipes arrive as `.indirect` `UITouch` streams and NEVER as
//  arrow presses. A focusless surface that installs only one path is dead to
//  half the remotes in the field. This binding installs BOTH:
//
//  - per-direction arrow-press taps, plus optional native long-press holds
//    (tap requires the long to fail — the same mechanism
//    `PlayerContainerViewController.setupDirectionalGestures` uses)
//  - per-direction `UISwipeGestureRecognizer`s constrained to `.indirect`
//    touches with `allowedPressTypes = []` (a tvOS swipe recognizer otherwise
//    waits on a `.select` press)
//
//  and funnels both into one tap callback per direction, so a surface cannot
//  adopt one transport without the other.
//
//  FOCUSLESS surfaces only. On a surface with focusable content the focus
//  engine already translates every remote's swipes and clicks into focus
//  moves, and a swipe recognizer that reaches `.began` CANCELS the competing
//  focus interaction — installing this there steals navigation from every
//  touch remote. A single invisible focus anchor (the focusless-modal
//  pattern) is fine; sibling focus targets are not. If the host surface is
//  only sometimes focusless, mount the binding only during that state.
//

import UIKit

@MainActor
final class DirectionalInputBinding: NSObject {

    enum Direction: CaseIterable {
        case up, down, left, right

        var pressType: UIPress.PressType {
            switch self {
            case .up: return .upArrow
            case .down: return .downArrow
            case .left: return .leftArrow
            case .right: return .rightArrow
            }
        }

        var swipeDirection: UISwipeGestureRecognizer.Direction {
            switch self {
            case .up: return .up
            case .down: return .down
            case .left: return .left
            case .right: return .right
            }
        }
    }

    /// Arrow-press tap OR indirect-touch swipe in this direction.
    private let onTap: (Direction) -> Void
    /// Arrow press held past `InputConfig.holdThreshold` (press path only —
    /// a touch surface expresses "hold" as repeated swipes instead).
    private let onHold: ((Direction) -> Void)?

    private var directionByRecognizer: [ObjectIdentifier: Direction] = [:]

    /// Installs recognizers for `directions` on `view`. Directions listed in
    /// `holds` also get a long-press recognizer whose `.began` fires `onHold`
    /// (their taps then only fire on release before the hold threshold).
    /// Keep the binding alive for the life of the view (store it on the
    /// owning controller).
    init(
        view: UIView,
        directions: [Direction],
        holds: [Direction] = [],
        onTap: @escaping (Direction) -> Void,
        onHold: ((Direction) -> Void)? = nil
    ) {
        self.onTap = onTap
        self.onHold = onHold
        super.init()

        for direction in directions {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.allowedPressTypes = [NSNumber(value: direction.pressType.rawValue)]
            view.addGestureRecognizer(tap)
            directionByRecognizer[ObjectIdentifier(tap)] = direction

            if holds.contains(direction) {
                let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLong(_:)))
                long.allowedPressTypes = [NSNumber(value: direction.pressType.rawValue)]
                long.minimumPressDuration = InputConfig.holdThreshold
                view.addGestureRecognizer(long)
                directionByRecognizer[ObjectIdentifier(long)] = direction
                tap.require(toFail: long)
            }

            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction.swipeDirection
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            swipe.allowedPressTypes = []
            view.addGestureRecognizer(swipe)
            directionByRecognizer[ObjectIdentifier(swipe)] = direction
        }
    }

    /// The direction a recognizer installed by this binding serves.
    func direction(of recognizer: UIGestureRecognizer) -> Direction? {
        directionByRecognizer[ObjectIdentifier(recognizer)]
    }

    @objc func handleTap(_ recognizer: UIGestureRecognizer) {
        guard let direction = direction(of: recognizer) else { return }
        onTap(direction)
    }

    @objc func handleSwipe(_ recognizer: UIGestureRecognizer) {
        guard let direction = direction(of: recognizer) else { return }
        onTap(direction)
    }

    @objc func handleLong(_ recognizer: UIGestureRecognizer) {
        guard recognizer.state == .began, let direction = direction(of: recognizer) else { return }
        onHold?(direction)
    }
}
