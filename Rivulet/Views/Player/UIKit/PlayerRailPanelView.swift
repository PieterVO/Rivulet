//
//  PlayerRailPanelView.swift
//  Rivulet
//
//  The one floating glass panel shared by the rail's CC, audio, and
//  info buttons (Task 5) and the Up Next button (Task 6). Presents
//  a caller-supplied content view above the rail, anchored near the
//  source button; Menu dismisses; content owns its own internal
//  focus (row list landing / selected-row scroll for the track
//  list, whole-view scroll focus for the info sheet).
//

import UIKit

final class PlayerRailPanelView: UIView {

    private enum Metrics {
        static let cornerRadius: CGFloat = 20
        static let railGap: CGFloat = 12
        static let padding: CGFloat = 20
        static let maxHeight: CGFloat = 560
        static let presentTranslationY: CGFloat = 12
        static let presentDuration: TimeInterval = 0.2
        static let dismissDuration: TimeInterval = 0.15
    }

    var onDismiss: (() -> Void)?

    private let backgroundEffectView: UIVisualEffectView
    private let tintView = UIView()
    private let content: UIView
    private var didDismiss = false

    private init(content: UIView) {
        self.content = content
        if #available(tvOS 26.0, *) {
            backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)

        // Shadow lives on the unclipped self layer (two-layer split,
        // same pattern as PlayerRailView): the drop shadow needs an
        // unclipped layer to paint outside the bounds, while the
        // glass/tint below clip themselves individually so the blur
        // doesn't smear past the rounded corners.
        //
        // The panel floats detached just above the rail with all four
        // corners rounded. A flush weld can't work: each glass surface
        // draws its own edge highlight and border, so two abutting
        // pieces always show a double seam. Border/shadow deliberately
        // match the rail so the two read as one material family.
        layer.cornerRadius = Metrics.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.1).cgColor

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 24
        layer.shadowOffset = CGSize(width: 0, height: 10)

        backgroundEffectView.clipsToBounds = true
        backgroundEffectView.layer.cornerRadius = Metrics.cornerRadius
        backgroundEffectView.layer.cornerCurve = .continuous

        tintView.backgroundColor = UIColor(red: 16/255, green: 18/255, blue: 24/255, alpha: 0.5)
        tintView.clipsToBounds = true
        tintView.layer.cornerRadius = Metrics.cornerRadius
        tintView.layer.cornerCurve = .continuous

        [backgroundEffectView, tintView, content].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.maxHeight),

            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padding),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.padding),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Panel's own layer has no drawn contents, so the animated
        // shadow needs an explicit path or Core Animation rasterizes
        // offscreen every frame of the rise-in.
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: Metrics.cornerRadius
        ).cgPath
    }

    // MARK: - Presentation

    /// Builds, adds to `container`, and animates the panel in floating
    /// just above `rail`, right-aligned with the rail's trailing edge
    /// (button projection intentionally simplified to the rail's own
    /// trailing edge rather than the individual button — see brief note).
    @discardableResult
    static func present(content: UIView, width: CGFloat, in container: UIView, aboveRail rail: UIView, towards button: UIView) -> PlayerRailPanelView {
        let panel = PlayerRailPanelView(content: content)
        container.addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false

        // The info sheet is one big scrollable focus target with nothing
        // inside it to highlight, so the panel ring itself carries the
        // focus treatment — brightened while the sheet holds focus.
        (content as? CardInfoView)?.onFocusChange = { [weak panel] focused in
            panel?.setFocusHighlight(focused)
        }

        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(equalToConstant: width),
            panel.bottomAnchor.constraint(equalTo: rail.topAnchor, constant: -Metrics.railGap),
            panel.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
        ])

        panel.alpha = 0
        panel.transform = CGAffineTransform(translationX: 0, y: Metrics.presentTranslationY)
        container.layoutIfNeeded()

        // Content that needs to position itself against real geometry
        // before the first visible frame (e.g. Up Next's scroll-to-current
        // row) must do so here — after the panel has its real
        // width/position constraints and `layoutIfNeeded()` above has
        // resolved them, but before the rise-in animation below renders
        // anything. Doing it any later (e.g. from the content's own
        // `didMoveToWindow()`, which fires earlier during `addSubview`
        // above, against not-yet-laid-out geometry) makes the correction
        // visibly animate in as the real layout lands.
        (content as? UpNextListView)?.prepareForPresentation()

        UIView.animate(withDuration: Metrics.presentDuration) {
            panel.alpha = 1
            panel.transform = .identity
        }

        container.setNeedsFocusUpdate()
        container.updateFocusIfNeeded()

        return panel
    }

    func setFocusHighlight(_ focused: Bool) {
        layer.borderColor = UIColor.white.withAlphaComponent(focused ? 0.3 : 0.1).cgColor
    }

    func dismissPanel() {
        guard !didDismiss else { return }
        didDismiss = true
        UIView.animate(withDuration: Metrics.dismissDuration, animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: Metrics.presentTranslationY)
        }, completion: { [weak self] _ in
            guard let self else { return }
            self.removeFromSuperview()
            self.onDismiss?()
        })
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { true }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [content] }

    /// Fences focus inside the panel while it's still in the window
    /// (i.e. hasn't finished its dismiss animation/removal yet) —
    /// mirrors the fullScreenCover-style isolation the rest of the
    /// chrome relies on, scoped here since the panel isn't presented
    /// via a system modal.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard window != nil else { return true }
        if let next = context.nextFocusedView, next.isDescendant(of: self) {
            return true
        }
        return false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            dismissPanel()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            // Menu is fully consumed at began; an unswallowed ended
            // phase bubbles to the system and peels an extra layer
            // (dismisses the player itself on top of closing the
            // panel) — same trap as the container's own Menu handling.
            return
        }
        super.pressesEnded(presses, with: event)
    }
}
