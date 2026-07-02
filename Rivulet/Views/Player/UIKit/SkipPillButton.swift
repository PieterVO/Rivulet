//
//  SkipPillButton.swift
//  Rivulet
//
//  "Skip Intro" / "Skip Credits" capsule, matching the system-player pill:
//  translucent glass at rest, white fill with black text when focused.
//  Extracted from PlayerTransportBarView so PlayerContainerViewController
//  can host it directly as a floating pill above the locked scrubber.
//

import UIKit

final class SkipPillButton: UIButton {

    private let effectView: UIVisualEffectView

    init() {
        if #available(tvOS 26.0, *) {
            effectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            effectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)

        effectView.isUserInteractionEnabled = false
        effectView.clipsToBounds = true
        effectView.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        insertSubview(effectView, at: 0)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setTitleColor(.white, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        contentEdgeInsets = UIEdgeInsets(top: 12, left: 26, bottom: 12, right: 26)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        layer.cornerCurve = .continuous
        effectView.layer.cornerRadius = bounds.height / 2
        effectView.layer.cornerCurve = .continuous
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.transform = isFocused ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
            self.effectView.backgroundColor = isFocused ? .white : UIColor.white.withAlphaComponent(0.1)
            self.setTitleColor(isFocused ? .black : .white, for: .normal)
        }, completion: nil)
    }
}
