// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InfoScrollView.swift
//  Rivulet
//
//  Focusable scroll surface shared by the player's info sheets (Info tab
//  `CardInfoView` and Advanced tab `CardStatsView`). A plain UIScrollView is
//  inert on tvOS — with no focusable rows inside, the focus engine never
//  scrolls it and remote input goes nowhere. This takes focus itself, lets
//  the remote's indirect swipes drive the pan gesture directly, and steps the
//  offset on discrete up/down edge clicks.
//
//  When it is already at the top and Up is pressed, it does not swallow the
//  press for a scroll it can't perform; instead it fires `onEscapeUp` so the
//  hosting tab container can move focus up to the tab bar. With no handler
//  set (e.g. the hls route with no tab bar) the press is simply swallowed —
//  the historical end-of-travel behavior.
//

import UIKit

final class InfoScrollView: UIScrollView {

    /// Fires when the scroll surface gains/loses focus, so the hosting panel
    /// can brighten its own boundary (the sheet can't draw the panel ring).
    var onFocusChange: ((Bool) -> Void)?

    /// Fires on an Up press while already scrolled to the top — the signal for
    /// the tab container to move focus up to the tab bar. nil when there is no
    /// tab bar to escape to (the press is then swallowed, as before).
    var onEscapeUp: (() -> Void)?

    private static let clickStep: CGFloat = 240

    override init(frame: CGRect) {
        super.init(frame: frame)
        panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFocused: Bool { true }

    private var isAtTop: Bool {
        contentOffset.y <= -adjustedContentInset.top + 0.5
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        if focused {
            flashScrollIndicators()
        }
        onFocusChange?(focused)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .upArrow:
                // At the top there is nothing to scroll into — hand the press
                // to the container so focus can leave upward to the tab bar.
                if isAtTop {
                    onEscapeUp?()
                } else {
                    step(up: true)
                }
                return
            case .downArrow:
                // Down never escapes: the tab bar sits above the content, so
                // the only vertical exit is upward. Swallow at the bottom edge
                // too (the panel's focus fence would refuse a move anyway).
                step(up: false)
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    private func step(up: Bool) {
        let topOffset = -adjustedContentInset.top
        let maxOffset = max(topOffset, contentSize.height + adjustedContentInset.bottom - bounds.height)
        let target = contentOffset.y + (up ? -Self.clickStep : Self.clickStep)
        let clamped = min(max(target, topOffset), maxOffset)
        guard clamped != contentOffset.y else { return }
        setContentOffset(CGPoint(x: contentOffset.x, y: clamped), animated: true)
    }
}
