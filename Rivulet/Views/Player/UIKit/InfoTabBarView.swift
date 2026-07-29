// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InfoTabBarView.swift
//  Rivulet
//
//  Two-pill tab bar (Info | Advanced) for the player's Now Playing popup —
//  the sibling of `InsightsTabBarView` for the trivia panel. Kept as its own
//  type rather than sharing that bar: this one has a fixed two-tab enum and
//  needs no horizontal scroll (two pills always fit the panel width). The pill
//  visuals are copied token-for-token from `InsightsTabPillView`; if you
//  restyle one, restyle both so the two tab bars stay identical.
//

import UIKit
import os

/// TEMP diagnostic instrumentation — see the matching note in
/// `PlayerInfoTabsView.swift`. Remove once the intermittent tab-switch /
/// can't-move-Down reports are confirmed and fixed from a captured log.
private let infoTabBarLog = Logger(subsystem: "com.rivulet.app", category: "PlayerInfoTab")

final class InfoTabBarView: UIView {

    enum Tab: CaseIterable {
        case info
        case advanced
        var title: String {
            switch self {
            case .info: return "Info"
            case .advanced: return "Advanced"
            }
        }
    }

    private enum Metrics {
        static let pillSpacing: CGFloat = 8
        static let barHeight: CGFloat = 56
    }

    var onSelect: ((Tab) -> Void)?

    private let stack = UIStackView()
    private var pills: [(tab: Tab, view: InfoTabPillView)] = []
    private var selected: Tab

    init(selected: Tab) {
        self.selected = selected
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = Metrics.pillSpacing
        // Pills keep their intrinsic height, centered, so the focused 1.05
        // scale has vertical headroom inside the bar.
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.barHeight),
            // Leading-aligned so the selected pill's left edge lines up with
            // the info sheet's leading text edge below it.
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Uniform pill width sized to the widest title at the HEAVIEST weight a
        // pill ever renders (.heavy, the active/focused state) so the bolder
        // text never overflows a width computed from a lighter weight. Same
        // idiom as InsightsTabBarView.
        let measuringFont = UIFont.systemFont(ofSize: 20, weight: .heavy)
        let widestTitle = Tab.allCases
            .map { ceil(($0.title as NSString).size(withAttributes: [.font: measuringFont]).width) }
            .max() ?? 0
        let pillWidth = widestTitle + 40

        for tab in Tab.allCases {
            let pill = InfoTabPillView()
            pill.configure(title: tab.title, isSelected: tab == selected)
            pill.onSelected = { [weak self] in self?.handlePillSelected(tab) }
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: pillWidth).isActive = true
            stack.addArrangedSubview(pill)
            pills.append((tab, pill))
        }
    }

    private func handlePillSelected(_ tab: Tab) {
        guard tab != selected else { return }
        setSelected(tab)
        onSelect?(tab)
    }

    /// Updates which pill renders as selected without firing `onSelect` — the
    /// host calls this to keep the bar in sync after driving a tab change.
    func setSelected(_ tab: Tab) {
        selected = tab
        for (pillTab, pillView) in pills {
            pillView.configure(title: pillTab.title, isSelected: pillTab == tab)
        }
    }

    /// Keeps Left/Right focus INSIDE the bar (a `pressesBegan` guard can't:
    /// the engine consumes a directional press the instant it finds any
    /// candidate). `shouldUpdateFocus` is the authoritative veto — the engine
    /// calls it on the ancestors of the currently-focused item, and any
    /// `false` cancels the move. Only horizontal exits are vetoed; Down passes
    /// through to the content below.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard context.focusHeading == .left || context.focusHeading == .right else {
            // TEMP: the engine only calls this once it has already FOUND a
            // candidate, so a Down press that logs a press but never logs here
            // means no candidate existed at all — see pressesBegan's note.
            infoTabBarLog.notice("shouldUpdateFocus (non-horizontal): heading=\(context.focusHeading.rawValue) next=\(String(describing: context.nextFocusedView))")
            return super.shouldUpdateFocus(in: context)
        }
        let prevIsPill = context.previouslyFocusedView.map(containsPill) ?? false
        let nextIsPill = context.nextFocusedView.map(containsPill) ?? false
        if prevIsPill && !nextIsPill {
            infoTabBarLog.notice("shouldUpdateFocus VETOED horizontal exit from pill row")
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }

    private func containsPill(_ view: UIView) -> Bool {
        pills.contains { view === $0.view || view.isDescendant(of: $0.view) }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let selectedPill = pills.first(where: { $0.tab == selected })?.view {
            return [selectedPill]
        }
        return pills.first.map { [$0.view] } ?? []
    }
}

/// Capsule pill, one per tab. Three visual states, distinct on purpose:
///   • rest        — clear, dim label.
///   • selected    — a translucent liquid-glass capsule.
///   • focused     — a bright opaque white capsule, black label, 1.05 scale.
/// Copied from `InsightsTabPillView` (trivia panel) — keep the two in sync.
private final class InfoTabPillView: UIControl {

    private let label = UILabel()
    private let glassView: UIVisualEffectView = {
        if #available(tvOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            return UIVisualEffectView(effect: UIBlurEffect(style: .light))
        }
    }()
    private var isSelectedTab = false
    private var isFocusedPill = false

    var onSelected: (() -> Void)?

    override var canBecomeFocused: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous

        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.clipsToBounds = true
        glassView.isUserInteractionEnabled = false
        glassView.isHidden = true
        addSubview(glassView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textAlignment = .center
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        glassView.layer.cornerRadius = bounds.height / 2
    }

    // Select does not fire .primaryActionTriggered on a plain UIControl on
    // tvOS; handle the press directly.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            infoTabBarLog.notice("pill Select received, isFocused=\(self.isFocused)")
            onSelected?()
            return
        }
        // TEMP: log arrow presses WITHOUT consuming them (super still runs, so
        // the engine's own handling is untouched). This is the discriminator
        // for the "can't move Down into the content" report — pair it with the
        // shouldUpdateFocus/didUpdateFocus logs and read it as:
        //   press logged, then focus ENTERED  → working
        //   press logged, shouldUpdateFocus false → a veto is blocking it
        //   press logged, nothing else       → engine found NO candidate
        //                                      (geometry/focusability)
        //   nothing logged at all            → the press never arrived
        //                                      (something upstream ate it)
        for press in presses where press.type == .downArrow || press.type == .upArrow {
            infoTabBarLog.notice("pill '\(self.label.text ?? "?")' got \(press.type == .downArrow ? "DOWN" : "UP") arrow, isFocused=\(self.isFocused)")
        }
        super.pressesBegan(presses, with: event)
    }

    func configure(title: String, isSelected: Bool) {
        label.text = title
        isSelectedTab = isSelected
        applyStyle()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        isFocusedPill = context.nextFocusedView === self
        if isFocusedPill {
            infoTabBarLog.notice("pill '\(self.label.text ?? "?")' GAINED focus")
        } else if context.previouslyFocusedView === self {
            infoTabBarLog.notice("pill '\(self.label.text ?? "?")' LOST focus, next=\(String(describing: context.nextFocusedView))")
        }
        coordinator.addCoordinatedAnimations({
            self.applyStyle()
            self.transform = self.isFocusedPill ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
        }, completion: nil)
    }

    private func applyStyle() {
        label.font = .systemFont(ofSize: 20, weight: (isFocusedPill || isSelectedTab) ? .heavy : .bold)
        if isFocusedPill {
            glassView.isHidden = true
            backgroundColor = UIColor.white.withAlphaComponent(0.9)
            label.textColor = .black
        } else if isSelectedTab {
            glassView.isHidden = false
            backgroundColor = .clear
            label.textColor = .white
        } else {
            glassView.isHidden = true
            backgroundColor = .clear
            label.textColor = UIColor.white.withAlphaComponent(0.72)
        }
    }
}
