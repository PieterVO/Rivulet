// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsTabBarView.swift
//  Rivulet
//
//  Pill tab bar for the Insights panel (Docs/superpowers/specs/
//  2026-07-08-insights-toptrivia-tabs-design.md). Replaces the single
//  combined trivia+cast scrolling list with tab-scoped browsing: Top 10,
//  Cast, then one pill per category that has visible facts. Visual/
//  interaction pattern generalized from `SeasonPillView` (capsule shape,
//  selected/focused dual-state styling, focus-previews/select-commits) —
//  that type stays coupled to MediaDetail's season selector; this is a
//  sibling for the player rail panel, not a shared subclass, since the two
//  hosts drive focus differently (season pills are host-gated by
//  `focusEnabled`; this bar is always focusable while in `.list` state).
//

import UIKit

/// One selectable tab in the Insights panel's pill bar.
enum InsightsTab: Hashable {
    case topTen
    case cast
    case category(TriviaCategory)
}

final class InsightsTabBarView: UIView {

    private enum Metrics {
        static let pillSpacing: CGFloat = 8
        static let barHeight: CGFloat = 56
        /// Horizontal inset inside the clipping scroll view so a focused
        /// pill's 1.05 scale doesn't clip at the bar's edges — mirrors
        /// InsightsCastListView's rowInset.
        static let pillInset: CGFloat = 8
    }

    var onSelect: ((InsightsTab) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var pills: [(tab: InsightsTab, view: InsightsTabPillView)] = []
    private var selected: InsightsTab

    init(tabs: [InsightsTab], selected: InsightsTab) {
        self.selected = selected
        super.init(frame: .zero)
        setUp(tabs: tabs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp(tabs: [InsightsTab]) {
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        // UIScrollView clips by default (that's what keeps CardInfoView's
        // content inside the panel); keep it so pills beyond the panel's
        // width stay hidden until the self-driven scroll reveals them.
        scrollView.clipsToBounds = true
        // Same rationale as InsightsFilmographyRowView/InsightsCastListView:
        // the focus engine's own scroll-to-visible fights a self-driven
        // offset, and with more pills than fit the panel's fixed width
        // (confirmed bug: pills ran off the popup edge with no way to
        // reach them), this bar must drive its own horizontal scroll from
        // didUpdateFocus rather than rely on the disabled default.
        scrollView.isScrollEnabled = false
        stack.axis = .horizontal
        stack.spacing = Metrics.pillSpacing
        // Pills keep their intrinsic height, centered in the bar, so the
        // focused 1.05 scale has vertical headroom inside the clip.
        stack.alignment = .center

        [scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        scrollView.addSubview(stack)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.barHeight),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Metrics.pillInset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Metrics.pillInset),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        // Uniform pill width: size every pill to the widest title so the bar
        // reads as a consistent row of tabs rather than ragged chips. Measure
        // at the HEAVIEST weight a pill ever renders (.heavy, the active
        // state) so the active pill's bolder text never overflows the width
        // computed from a lighter weight (that truncated a lone "Cast" to
        // "C…"). The width is a floor (>=), and the label keeps required
        // compression resistance, so a pill can never be narrower than its
        // own text regardless of the measurement.
        let measuringFont = UIFont.systemFont(ofSize: 20, weight: .heavy)
        let widestTitle = tabs
            .map { ceil((Self.title(for: $0) as NSString).size(withAttributes: [.font: measuringFont]).width) }
            .max() ?? 0
        let pillWidth = widestTitle + 40

        for tab in tabs {
            let pill = InsightsTabPillView()
            pill.configure(title: Self.title(for: tab), isSelected: tab == selected)
            pill.onSelected = { [weak self] in self?.handlePillSelected(tab) }
            pill.onFocused = { [weak self] coordinator in
                self?.scrollPillToCenter(pill, coordinator: coordinator)
            }
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: pillWidth).isActive = true
            stack.addArrangedSubview(pill)
            pills.append((tab, pill))
        }
    }

    /// Self-driven horizontal scroll (scrollView.isScrollEnabled = false
    /// above), center-anchored: the focused pill is pulled toward the bar's
    /// midpoint, clamped at the content edges. Near the start/end of the
    /// row focus visibly walks pill-to-pill; in the middle the pills stream
    /// under a stationary focus position — so a partially-visible neighbor
    /// always signals that more tabs exist off-edge.
    private func scrollPillToCenter(_ pill: InsightsTabPillView, coordinator: UIFocusAnimationCoordinator) {
        let pillFrameInScroll = pill.convert(pill.bounds, to: scrollView)
        let targetX = pillFrameInScroll.midX - scrollView.bounds.width / 2
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let clamped = min(max(0, targetX), maxX)
        guard abs(clamped - scrollView.contentOffset.x) > 0.5 else { return }
        coordinator.addCoordinatedAnimations({
            self.scrollView.contentOffset.x = clamped
        }, completion: nil)
    }

    /// Keeps Left/Right focus INSIDE the bar. A `pressesBegan` guard can't
    /// do this: the focus engine consumes a directional press the instant it
    /// finds any candidate, so an off-the-end Right (whose diagonal search
    /// cone finds a list row below) moves focus and never delivers the press
    /// here. `shouldUpdateFocus` is the authoritative veto — the engine calls
    /// it on the ancestors of the currently-focused item (this bar is one),
    /// and any `false` cancels the move, so focus holds on the edge pill.
    /// Only horizontal exits are vetoed; Down (pill → list) passes through.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard context.focusHeading == .left || context.focusHeading == .right else {
            return super.shouldUpdateFocus(in: context)
        }
        let prevIsPill = context.previouslyFocusedView.map(containsPill) ?? false
        let nextIsPill = context.nextFocusedView.map(containsPill) ?? false
        if prevIsPill && !nextIsPill { return false }
        return super.shouldUpdateFocus(in: context)
    }

    private func containsPill(_ view: UIView) -> Bool {
        pills.contains { view === $0.view || view.isDescendant(of: $0.view) }
    }

    private func handlePillSelected(_ tab: InsightsTab) {
        guard tab != selected else { return }
        setSelected(tab)
        onSelect?(tab)
    }

    /// Updates which pill renders as selected without firing `onSelect` —
    /// the host calls this to keep the bar in sync after driving a tab
    /// change itself (e.g. falling back to `.cast` when the active
    /// category's last fact is suppressed at runtime).
    func setSelected(_ tab: InsightsTab) {
        selected = tab
        for (pillTab, pillView) in pills {
            pillView.configure(title: Self.title(for: pillTab), isSelected: pillTab == tab)
        }
    }

    /// Which tabs should be offered given the panel's current cast/trivia
    /// inputs — pure, no UIKit dependency, directly unit-testable. Order:
    /// Top 10 (if >=1 qualifying fact), Cast (if non-empty), then one pill
    /// per `TriviaCategory` (in `TriviaCategory.allCases` declaration order)
    /// that has >=1 visible fact after spoiler/suppression filtering.
    static func availableTabs(
        cast: [MediaPerson],
        trivia: TitleTrivia?,
        suppressedTriviaIDs: Set<String>,
        hideSpoilers: Bool
    ) -> [InsightsTab] {
        var tabs: [InsightsTab] = []
        if let trivia, !trivia.topTenFacts(hideSpoilers: hideSpoilers, suppressed: suppressedTriviaIDs).isEmpty {
            tabs.append(.topTen)
        }
        if !cast.isEmpty {
            tabs.append(.cast)
        }
        if let trivia {
            let visible = trivia.visibleFacts(hideSpoilers: hideSpoilers, suppressed: suppressedTriviaIDs)
            for category in TriviaCategory.allCases where visible.contains(where: { $0.category == category }) {
                tabs.append(.category(category))
            }
        }
        return tabs
    }

    static func title(for tab: InsightsTab) -> String {
        switch tab {
        case .topTen: return "Top 10"
        case .cast: return "Cast"
        case .category(let category): return category.tabDisplayName
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let selectedPill = pills.first(where: { $0.tab == selected })?.view {
            return [selectedPill]
        }
        return pills.first.map { [$0.view] } ?? []
    }

    /// Whether focus currently sits on one of this bar's pills. Consulted
    /// by `InsightsPanelContainerView.pressesBegan` to decide whether a
    /// Down press should escape back into the list below (the reverse of
    /// the Up escape — the focus engine's own directional search does not
    /// reliably cross the scroll-view boundaries between the two).
    var containsFocus: Bool {
        guard let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView else { return false }
        return focused.isDescendant(of: self)
    }
}

/// Capsule pill, one per tab. Three visual states, distinct on purpose:
///   • rest        — clear, dim label.
///   • selected    — a translucent liquid-glass capsule (the current tab
///                    reads as present without competing with focus).
///   • focused     — a bright opaque white capsule, black label, 1.05 scale.
/// Selection and focus are independent, so the selected tab keeps its glass
/// chip while focus is on a different pill. Select (not mere focus) commits
/// the change. Kept as its own type rather than reusing `SeasonPillView`
/// (that type's `focusEnabled` gating and 31pt sizing don't fit this
/// always-focusable, compact bar).
private final class InsightsTabPillView: UIControl {

    private let label = UILabel()
    /// Liquid-glass background shown only in the selected-not-focused state.
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
    /// Invoked whenever this pill takes focus — lets the host `InsightsTabBarView`
    /// scroll it into view, since this pill has no awareness of its own
    /// scroll container.
    var onFocused: ((UIFocusAnimationCoordinator) -> Void)?

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
        // Pills share one uniform width (sized to the widest title by the
        // hosting bar), so shorter titles center within it.
        label.textAlignment = .center
        // Never truncate a pill's own title — the pill grows to fit it.
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
    // tvOS; handle the press directly (same trap as InsightsCastRowButton /
    // UpNextRowButton).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .select {
            onSelected?()
            return
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
        coordinator.addCoordinatedAnimations({
            self.applyStyle()
            self.transform = self.isFocusedPill ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
        }, completion: nil)
        if isFocusedPill {
            onFocused?(coordinator)
        }
    }

    private func applyStyle() {
        // Bold throughout (TV legibility); the active pill goes heavier still.
        label.font = .systemFont(ofSize: 20, weight: (isFocusedPill || isSelectedTab) ? .heavy : .bold)
        if isFocusedPill {
            // Bright, opaque — the unambiguous focus target.
            glassView.isHidden = true
            backgroundColor = UIColor.white.withAlphaComponent(0.9)
            label.textColor = .black
        } else if isSelectedTab {
            // Current tab: translucent liquid glass, softer than focus.
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
