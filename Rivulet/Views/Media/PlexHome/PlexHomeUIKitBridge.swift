// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexHomeUIKitBridge.swift
//  Rivulet
//
//  SwiftUI bridge to host `PlexHomeViewController` (UIKit/TVUIKit home).
//  All navigation is handled inside UIKit.
//

import SwiftUI
import UIKit

struct PlexHomeUIKitBridge: UIViewControllerRepresentable {
    /// Surface to render: .home (default) or .library(key:title:). Fixed for
    /// the lifetime of the hosted controller — library call sites must `.id`
    /// the container by library key so a key change rebuilds the VC.
    var mode: HomeMode = .home

    /// The one Home controller, handed to every make: SwiftUI identity churn at launch otherwise
    /// builds a second full home. Library mode is not cached; each library gets `.id(key)`.
    @MainActor private static var sharedHomeVC: PlexHomeViewController?

    func makeUIViewController(context: Context) -> PlexHomeViewController {
        if case .library = mode { StartupTimer.mark("bridge.makeUIViewController (library)") }
        else { StartupTimer.mark("bridge.makeUIViewController (home)") }

        let vc: PlexHomeViewController
        if case .home = mode {
            if let shared = Self.sharedHomeVC {
                StartupTimer.mark("bridge reusing shared home VC")
                vc = shared
            } else {
                vc = PlexHomeViewController(mode: mode)
                Self.sharedHomeVC = vc
            }
        } else {
            vc = PlexHomeViewController(mode: mode)
        }

        return vc
    }

    func updateUIViewController(_ uiViewController: PlexHomeViewController, context: Context) {}
}
