// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// Grab-to-move on a focus list or grid: arrow presses and touch swipes step the held item,
/// Select drops it. The host starts it, locks focus while `isMoving` and routes Menu to `cancel()`.
@MainActor
final class GrabReorderController: NSObject {
    enum Axis: Equatable { case vertical, grid(columns: Int) }

    private(set) var isMoving = false
    /// The held item's current slot.
    private(set) var index = 0
    /// Set by the drop (and a host's grab hold) so the same Select does not also select the item.
    var swallowsNextSelect = false

    private let axis: Axis
    private let count: () -> Int
    private let canMove: (_ from: Int, _ to: Int) -> Bool
    private let onStep: (_ from: Int, _ to: Int) -> Void
    private let onDrop: (_ original: Int, _ final: Int) -> Void
    private let onCancel: ((_ original: Int) -> Void)?
    private var original = 0
    private var headings: [ObjectIdentifier: UIFocusHeading] = [:]
    private var gestures: [UIGestureRecognizer] = []

    init(view: UIView, axis: Axis, count: @escaping () -> Int,
         canMove: @escaping (_ from: Int, _ to: Int) -> Bool,
         onStep: @escaping (_ from: Int, _ to: Int) -> Void,
         onDrop: @escaping (_ original: Int, _ final: Int) -> Void,
         onCancel: ((_ original: Int) -> Void)? = nil) {
        self.axis = axis
        self.count = count
        self.canMove = canMove
        self.onStep = onStep
        self.onDrop = onDrop
        self.onCancel = onCancel
        super.init()

        var moves: [(UIFocusHeading, UIPress.PressType, UISwipeGestureRecognizer.Direction)] = [
            (.up, .upArrow, .up), (.down, .downArrow, .down)
        ]
        if case .grid = axis { moves += [(.left, .leftArrow, .left), (.right, .rightArrow, .right)] }
        for (heading, press, direction) in moves {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleStep(_:)))
            tap.allowedPressTypes = [NSNumber(value: press.rawValue)]
            // A touch-surface swipe never arrives as an arrow press (#239).
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleStep(_:)))
            swipe.direction = direction
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            // Otherwise a tvOS swipe also waits on a Select press, racing the drop.
            swipe.allowedPressTypes = []
            for gesture in [tap, swipe] as [UIGestureRecognizer] {
                headings[ObjectIdentifier(gesture)] = heading
                gestures.append(gesture)
            }
        }
        let drop = UITapGestureRecognizer(target: self, action: #selector(handleDrop))
        drop.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        gestures.append(drop)
        // Live only while moving, so normal focus moves and swipe-to-scroll are untouched.
        gestures.forEach { $0.isEnabled = false; view.addGestureRecognizer($0) }
    }

    func begin(at index: Int) {
        guard !isMoving else { return }
        isMoving = true
        self.index = index
        original = index
        gestures.forEach { $0.isEnabled = true }
    }

    private func drop() {
        guard end() else { return }
        swallowsNextSelect = true
        onDrop(original, index)
    }

    /// Menu: the host puts the original order back. No-op when the host gave no cancel handler.
    func cancel() {
        guard onCancel != nil, end() else { return }
        swallowsNextSelect = false
        onCancel?(original)
    }

    private func step(_ heading: UIFocusHeading) {
        guard isMoving,
              let to = Self.target(from: index, direction: heading, axis: axis, count: count()),
              canMove(index, to) else { return }
        let from = index
        index = to
        onStep(from, to)
    }

    /// The slot one step away, nil at an edge. A grid's Down from the row above a short last row
    /// takes the last slot.
    static func target(from: Int, direction: UIFocusHeading, axis: Axis, count: Int) -> Int? {
        let last = count - 1
        let to: Int
        switch (direction, axis) {
        case (.up, .vertical), (.left, .grid): to = from - 1
        case (.down, .vertical), (.right, .grid): to = from + 1
        case (.up, .grid(let columns)): to = from - columns
        case (.down, .grid(let columns)):
            guard columns > 0, from / columns < last / columns else { return nil }
            to = min(from + columns, last)
        default: return nil
        }
        return to >= 0 && to <= last ? to : nil
    }

    private func end() -> Bool {
        guard isMoving else { return false }
        isMoving = false
        gestures.forEach { $0.isEnabled = false }
        return true
    }

    @objc private func handleStep(_ gesture: UIGestureRecognizer) {
        if let heading = headings[ObjectIdentifier(gesture)] { step(heading) }
    }

    @objc private func handleDrop() { drop() }
}

extension UIView {
    /// The grabbed item's wiggle (Apple Home's reorder look).
    func setReorderWiggle(_ on: Bool) {
        guard on else { layer.removeAnimation(forKey: "reorderWiggle"); return }
        let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wiggle.values = [-0.022, 0.022, -0.022]
        wiggle.duration = 0.34
        wiggle.repeatCount = .infinity
        wiggle.isRemovedOnCompletion = false
        layer.add(wiggle, forKey: "reorderWiggle")
    }
}
