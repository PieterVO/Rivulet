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
}

extension AnchoredPopupPresenting {
    func presentAnchored(in container: UIView, anchoredTo anchor: UIView, width: CGFloat) {
        alpha = 0
        container.addSubview(self)
        translatesAutoresizingMaskIntoConstraints = false

        let anchorFrame = anchor.convert(anchor.bounds, to: container)
        NSLayoutConstraint.activate([
            bottomAnchor.constraint(equalTo: container.topAnchor, constant: anchorFrame.minY - 16),
            leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: anchorFrame.minX),
            widthAnchor.constraint(equalToConstant: width),
        ])

        UIView.animate(withDuration: 0.2) {
            self.alpha = 1
        }
        UIAccessibility.post(notification: .screenChanged, argument: self)
        UIView.performWithoutAnimation {
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
        }
    }

    func dismissAnchored() {
        onDismiss?()
        UIView.animate(withDuration: 0.15, animations: {
            self.alpha = 0
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }
}
