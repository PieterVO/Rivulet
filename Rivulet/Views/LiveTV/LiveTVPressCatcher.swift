// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVPressCatcher.swift
//  Rivulet
//
//  UIKit input catcher for the focusless Live TV player state: arrow presses
//  (IR/CEC remotes, d-pad, keyboard) and touch-surface swipes both drive
//  seek/shuttle via DirectionalInputBinding; Menu maps to back.
//

import SwiftUI

import UIKit

struct LiveTVPressCatcher: UIViewControllerRepresentable {
    var onAction: (PlaybackInputAction) -> Void

    func makeUIViewController(context: Context) -> LiveTVPressCatcherController {
        let controller = LiveTVPressCatcherController()
        controller.onAction = onAction
        return controller
    }

    func updateUIViewController(_ uiViewController: LiveTVPressCatcherController, context: Context) {
        uiViewController.onAction = onAction
    }
}

final class LiveTVPressCatcherController: UIViewController {
    var onAction: ((PlaybackInputAction) -> Void)?

    // Only mounted while the Live TV shell is focusless (controls, channel
    // picker, and exit confirmation all hidden), so the binding's swipe
    // recognizers steal nothing from the focus engine.
    private var directionalInput: DirectionalInputBinding?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        directionalInput = DirectionalInputBinding(
            view: view,
            directions: [.left, .right],
            holds: [.left, .right],
            onTap: { [weak self] direction in
                self?.onAction?(.stepSeek(forward: direction == .right))
            },
            onHold: { [weak self] direction in
                self?.onAction?(.scrubNudge(forward: direction == .right))
            }
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            onAction?(.back)
            return
        }
        super.pressesBegan(presses, with: event)
    }

}

