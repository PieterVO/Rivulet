//
//  AnchoredPopupPresenting.swift
//  Rivulet
//
//  Shared anchored-popup presentation behavior for player transport-bar
//  popups (track picker, info panel). tvOS has no native anchored-popover
//  API; this is the common positioning/dismiss logic both popup types share.
//

import UIKit

protocol AnchoredPopupPresenting: UIView {
    var onDismiss: (() -> Void)? { get set }
    /// Fixed popup width; each conformer sets this to match its content.
    var presentedWidth: CGFloat { get }
}

extension AnchoredPopupPresenting {
    func present(in container: UIView, anchoredTo anchor: UIView) {
        presentAnchored(in: container, anchoredTo: anchor, width: presentedWidth)
    }

    func dismiss() {
        dismissAnchored()
    }

    private func presentAnchored(in container: UIView, anchoredTo anchor: UIView, width: CGFloat) {
        alpha = 0
        container.addSubview(self)
        translatesAutoresizingMaskIntoConstraints = false

        // System-player feel: the panel hangs directly over the button
        // that opened it - horizontally centered on the anchor, clamped
        // so it never leaves the screen, with a tight gap so the two
        // read as connected.
        let anchorFrame = anchor.convert(anchor.bounds, to: container)
        let margin: CGFloat = 60
        let gap: CGFloat = 12
        let halfWidth = width / 2
        let minCenterX = margin + halfWidth
        let maxCenterX = container.bounds.width - margin - halfWidth
        let centerX = min(max(anchorFrame.midX, minCenterX), max(minCenterX, maxCenterX))

        NSLayoutConstraint.activate([
            bottomAnchor.constraint(equalTo: container.topAnchor, constant: anchorFrame.minY - gap),
            leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: centerX - halfWidth),
            widthAnchor.constraint(equalToConstant: width),
            // Tall track lists compress (their scroll views scroll)
            // rather than growing past the top of the screen.
            topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: margin),
        ])

        // Grow out of the button: start slightly shrunk toward the
        // anchor and settle to identity alongside the fade.
        transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            .translatedBy(x: 0, y: 12)
        UIView.animate(withDuration: 0.25,
                       delay: 0,
                       usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0,
                       options: [.allowUserInteraction]) {
            self.alpha = 1
            self.transform = .identity
        }
        UIAccessibility.post(notification: .screenChanged, argument: self)
        UIView.performWithoutAnimation {
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
        }
    }

    private func dismissAnchored() {
        onDismiss?()
        UIView.animate(withDuration: 0.15, animations: {
            self.alpha = 0
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }
}
