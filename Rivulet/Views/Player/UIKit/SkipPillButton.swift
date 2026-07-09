//
//  SkipPillButton.swift
//  Rivulet
//
//  "Skip Intro" / "Skip Credits" / "Skip Ad" capsule, matching the
//  system-player pill: liquid glass at rest, white fill with black text when
//  focused. Hosted directly by PlayerContainerViewController as a floating
//  pill above (or, when the chrome is hidden, lower over) the scrubber.
//

import UIKit

final class SkipPillButton: UIButton {

    /// Fired on Select. Handled in `pressesBegan` because a tvOS UIButton
    /// does NOT fire `.primaryActionTriggered` on the Siri Remote Select
    /// press (same trap TransportControlButton documents) — relying on the
    /// action target silently sent the press elsewhere (it surfaced the rail
    /// and opened Subtitles instead of skipping).
    var onSelect: (() -> Void)?

    /// Asked on an Up/Down press while this pill holds focus. Returns `true`
    /// if the container handled it (chrome hidden → surface the transport
    /// controls), in which case the press is consumed; `false` lets the focus
    /// engine move focus normally (chrome up → Down returns to the rail).
    /// Left/Right always fall through to the container's seek gestures.
    var onDirectionalPress: ((UIPress.PressType) -> Bool)?

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
        titleLabel?.font = .systemFont(ofSize: 26, weight: .semibold)
        contentEdgeInsets = UIEdgeInsets(top: 16, left: 34, bottom: 16, right: 34)
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

    override var canBecomeFocused: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .select:
                // Swallow the Select DOWN and act on the UP (below). Skipping on
                // the down would hide the pill and hand focus back to the SwiftUI
                // layer mid-press, so the UP would land on its tap-to-show-controls
                // gesture and surface the rail. Consuming the whole press keeps it
                // on the pill, so a click just skips.
                return
            case .upArrow, .downArrow:
                // When the pill is the only focusable view (chrome hidden), the
                // engine finds no candidate and delivers the press here — the
                // container turns that into "surface the controls."
                if onDirectionalPress?(press.type) == true { return }
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onSelect?()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            return
        }
        super.pressesCancelled(presses, with: event)
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
