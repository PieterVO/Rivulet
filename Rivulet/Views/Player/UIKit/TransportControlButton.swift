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

    private let iconView = UIImageView()
    private let backgroundEffectView: UIVisualEffectView

    var onPress: (() -> Void)?

    init(icon: UIImage?, accessibilityLabel: String) {
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

        backgroundEffectView.layer.cornerRadius = Self.diameter / 2
        backgroundEffectView.clipsToBounds = true
        backgroundEffectView.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        backgroundEffectView.isUserInteractionEnabled = false

        addSubview(backgroundEffectView)
        addSubview(iconView)

        [backgroundEffectView, iconView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),

            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTarget(self, action: #selector(handlePress), for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handlePress() {
        onPress?()
    }

    override var canBecomeFocused: Bool { true }

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
