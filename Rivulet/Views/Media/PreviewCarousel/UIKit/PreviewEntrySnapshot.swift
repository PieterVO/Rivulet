// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PreviewEntrySnapshot.swift
//  Rivulet
//
//  UIKit-only handoff for the row -> preview carousel entrance. The presenter
//  captures visible source tile snapshots before presentation; the carousel VC
//  owns animating those views into its card geometry.
//

import UIKit

@MainActor
struct PreviewEntrySnapshot {
    let itemIndex: Int
    let sourceFrame: CGRect
    let snapshotView: UIView
}
