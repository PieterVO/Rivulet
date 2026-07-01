//
//  PlayerPillButton.swift
//  Rivulet
//
//  Focusable glass pill button for the player transport bar (Subtitles /
//  Audio / Info). Matches Rivulet's glass-row focus style: translucent
//  background, opacity-based border, 1.02x focus scale, spring animation.
//

import UIKit

final class PlayerPillButton: UIControl {

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let stack = UIStackView()
    private let backgroundEffectView: UIVisualEffectView
    private let borderLayer = CAShapeLayer()

    var onPress: (() -> Void)?

    init(icon: UIImage?, title: String) {
        if #available(tvOS 26.0, *) {
            backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)

        iconView.image = icon
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 18, weight: .medium)
        titleLabel.textColor = .white

        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)

        addSubview(backgroundEffectView)
        addSubview(stack)

        [backgroundEffectView, stack, iconView, titleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])

        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        backgroundEffectView.layer.cornerRadius = 22
        backgroundEffectView.layer.cornerCurve = .continuous
        backgroundEffectView.clipsToBounds = true

        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        backgroundEffectView.backgroundColor = UIColor.white.withAlphaComponent(0.08)

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
            let animator = UIViewPropertyAnimator(duration: 0.3, timingParameters: UISpringTimingParameters(dampingRatio: 0.7))
            animator.addAnimations {
                self.transform = isFocused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
                self.backgroundEffectView.backgroundColor = UIColor.white.withAlphaComponent(isFocused ? 0.18 : 0.08)
                self.layer.borderColor = UIColor.white.withAlphaComponent(isFocused ? 0.25 : 0.08).cgColor
            }
            animator.startAnimation()
        }, completion: nil)
    }
}
