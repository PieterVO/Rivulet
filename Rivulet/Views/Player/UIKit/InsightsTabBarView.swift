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

        // Uniform pill width: size every pill to the widest title so the
        // bar reads as a consistent row of tabs rather than ragged chips.
        let measuringFont = UIFont.systemFont(ofSize: 20, weight: .semibold)
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
            pill.widthAnchor.constraint(equalToConstant: pillWidth).isActive = true
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

    /// Left/Right at the row's edges are consumed so focus HOLDS on the
    /// first/last pill — otherwise the focus engine's directional search
    /// cone finds a list row below-diagonal and focus falls out of the bar.
    /// Runs here because presses are delivered to the focused pill and
    /// bubble up through this ancestor.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .leftArrow || press.type == .rightArrow {
            guard let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView,
                  let index = pills.firstIndex(where: { focused === $0.view || focused.isDescendant(of: $0.view) })
            else { continue }
            let atEdge = press.type == .leftArrow ? index == 0 : index == pills.count - 1
            if atEdge { return }
        }
        super.pressesBegan(presses, with: event)
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

/// Capsule pill, one per tab. Visual/interaction pattern mirrors
/// `SeasonPillView` (Views/Media/MediaDetail/UIKit/Cells/SeasonPillView.swift):
/// bright frosted capsule when selected OR focused, clear/dim otherwise,
/// 1.05x focus scale, select (not mere focus) commits the change. Kept as
/// its own type rather than reusing `SeasonPillView` directly since that
/// type's `focusEnabled` gating and `MediaDetail`-specific label sizing
/// (31pt) don't fit this bar's always-focusable, more compact context.
private final class InsightsTabPillView: UIControl {

    private let label = UILabel()
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

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 20, weight: .medium)
        // Pills share one uniform width (sized to the widest title by the
        // hosting bar), so shorter titles center within it.
        label.textAlignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
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
        label.font = .systemFont(ofSize: 20, weight: (isFocusedPill || isSelectedTab) ? .semibold : .medium)
        if isFocusedPill || isSelectedTab {
            backgroundColor = UIColor.white.withAlphaComponent(0.88)
            label.textColor = .black
        } else {
            backgroundColor = .clear
            label.textColor = UIColor.white.withAlphaComponent(0.72)
        }
    }
}
