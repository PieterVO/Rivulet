// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SamePressFocusGate.swift
//  Rivulet
//
//  The one gate for the same-press focus race, shared by the player's rail
//  panels (the Insights/trivia list and the Info popup's sheets).
//
//  The race: tvOS delivers `didUpdateFocus` a few milliseconds BEFORE the
//  `pressesBegan` for the SAME press. So any handler that reads "where is focus
//  now?" to decide what a directional press means is reading the state AFTER
//  the engine already acted on it. A handler that escapes focus upward when it
//  sees focus on the first row therefore fires on the very press that moved
//  focus onto that row: one Up press, two moves, and the first row is jumped
//  clean over (reported on the trivia panel's cast list — Up from item 1 landed
//  on the tabs instead of item 0).
//
//  The fix is always the same: ignore a press that arrives within a short
//  window of the last focus move, because that press IS the move. Each caller
//  keeps its own timestamp (set in `didUpdateFocus`) and asks here.
//
//  NOTE: `MediaItemDetailPageViewController` solves the same race with its own
//  ~60ms gate. It is not wired to this one — it works, it is a different
//  surface, and its window looks tuned on device rather than derived. Fold it
//  in only with a device pass to confirm the longer window is safe there.
//

import QuartzCore

enum SamePressFocusGate {

    /// How long after a focus move a directional press is assumed to BE that
    /// move. Long enough to cover the engine's few-ms lead with margin, short
    /// enough that a genuine second press is never swallowed.
    static let window: CFTimeInterval = 0.2

    /// Whether focus moved so recently that an arriving press should be treated
    /// as the press that caused it.
    ///
    /// Pass the time of the last focus move (`CACurrentMediaTime()` recorded in
    /// `didUpdateFocus`). A caller that has never seen focus move should hold
    /// `-.greatestFiniteMagnitude`, which is never inside the window.
    static func justMovedFocus(at lastMove: CFTimeInterval) -> Bool {
        CACurrentMediaTime() - lastMove <= window
    }
}
