// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TransportControlButton.swift
//  Rivulet
//
//  Circular icon button for the row below the transport scrubber, styled
//  after AVPlayerViewController's transport-bar controls (tvOS 15+):
//  translucent dark circle with a white glyph; focus inverts to a solid
//  white circle with a black glyph and scales up slightly.
//

import UIKit

final class TransportControlButton: UIControl {

    static let diameter: CGFloat = 64

    private let diameter: CGFloat
    private let iconView = UIImageView()
    private let backgroundEffectView: UIVisualEffectView

    var onPress: (() -> Void)?

    /// Fired instead of `onPress` when Select is held past `longPressThreshold`.
    /// Buttons without a handler keep firing `onPress` in `pressesBegan`
    /// (snappy, tvOS UIControl trap: `.primaryActionTriggered` never fires
    /// on Select); buttons with a handler defer to `pressesEnded`/a timer so
    /// they can distinguish a short press from a long one.
    var onLongPress: (() -> Void)?
    private var selectDownAt: Date?
    private var longPressTimer: Timer?
    private static let longPressThreshold: TimeInterval = 0.6

    init(icon: UIImage?, accessibilityLabel: String, diameter: CGFloat = TransportControlButton.diameter) {
        self.diameter = diameter
        if #available(tvOS 26.0, *) {
            backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)

        self.accessibilityLabel = accessibilityLabel
        isAccessibilityElement = true

        let config = UIImage.SymbolConfiguration(pointSize: 25, weight: .semibold)
        iconView.image = icon?.applyingSymbolConfiguration(config)
        iconView.tintColor = .white
        iconView.contentMode = .center

        backgroundEffectView.layer.cornerRadius = self.diameter / 2
        backgroundEffectView.clipsToBounds = true
        backgroundEffectView.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        backgroundEffectView.isUserInteractionEnabled = false

        addSubview(backgroundEffectView)
        addSubview(iconView)

        [backgroundEffectView, iconView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: self.diameter),
            heightAnchor.constraint(equalToConstant: self.diameter),

            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFocused: Bool { true }

    // Select does not fire .primaryActionTriggered on a plain UIControl
    // on tvOS; handle the press directly. Buttons without a long-press
    // handler fire onPress immediately here (unchanged, snappy behavior).
    // Buttons with a long-press handler wait: a timer firing before
    // release means "long press" (onLongPress); release before the
    // timer fires means "short press" (onPress).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            guard onLongPress != nil else {
                onPress?()
                return
            }
            selectDownAt = Date()
            longPressTimer?.invalidate()
            longPressTimer = Timer.scheduledTimer(withTimeInterval: Self.longPressThreshold, repeats: false) { [weak self] _ in
                guard let self, self.selectDownAt != nil else { return }
                self.selectDownAt = nil
                self.onLongPress?()
            }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            longPressTimer?.invalidate()
            longPressTimer = nil
            if selectDownAt != nil {
                selectDownAt = nil
                onPress?() // released before threshold: normal press
            }
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        selectDownAt = nil
        super.pressesCancelled(presses, with: event)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.transform = isFocused ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
            self.backgroundEffectView.backgroundColor = isFocused ? .white : UIColor.white.withAlphaComponent(0.1)
            self.iconView.tintColor = isFocused ? .black : .white
        }, completion: nil)
    }
}
