// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PillTabBarView.swift
//  Rivulet
//
//  THE pill tab bar for the player's rail panels — the Insights/trivia panel
//  (`InsightsPanelContainerView`) and the Now Playing Info popup
//  (`PlayerInfoTabsView`). One type, because the two used to be near-verbatim
//  copies of each other (`InsightsTabBarView` + `InfoTabBarView`, each with its
//  own private copy of the pill) whose only real difference was that the Info
//  one skipped the horizontal scroll on the grounds that its two pills always
//  fit. That reasoning expired the moment a third tab arrived (#267): a bar
//  that scrolls handles both cases, and one bar can't drift from the other.
//
//  Tabs are addressed by INDEX, not by a tab type. Every host already keeps an
//  ordered array of its own tab enum, so an index is all the coupling this
//  needs — no generic parameter, no shared protocol, no `AnyHashable`.
//
//  Behaviour worth knowing before touching it:
//    • Scroll is SELF-DRIVEN (`isScrollEnabled = false`) and centers the
//      focused pill. The focus engine's own scroll-to-visible fights a driven
//      offset — same reason `InsightsFilmographyRowView` and `InfoScrollView`
//      drive their own.
//    • `shouldUpdateFocus` vetoes horizontal exits so Left/Right can't escape
//      the bar. A `pressesBegan` guard cannot do this: the engine consumes a
//      directional press the instant it finds any candidate, and an
//      off-the-end Right finds the content below via its diagonal search cone.
//      Down passes through, so pill → content stays a native focus move.
//    • Pills are uniformly wide, measured at `.heavy` (the widest weight one
//      ever renders) with the label at required compression resistance, so the
//      active pill's bolder text can never truncate.
//

import UIKit

final class PillTabBarView: UIView {

    /// Horizontal inset of the pills inside the clipping scroll view, so a
    /// focused pill's 1.05 scale doesn't clip at the bar's edges.
    ///
    /// Hosts must inset the content BELOW the bar by the same amount, or the
    /// pill capsules sit proud of the content's leading edge. The Insights
    /// panel does this with its own matching `rowInset` (`InsightsCastListView`,
    /// `InsightsActorView`); the Info popup reads this constant directly.
    static let contentInset: CGFloat = 8

    private enum Metrics {
        static let pillSpacing: CGFloat = 8
        static let barHeight: CGFloat = 56
    }

    /// Fires with the index of the newly selected tab. Not called for a
    /// re-select of the current tab.
    var onSelect: ((Int) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var pills: [PillTabItemView] = []
    private var titles: [String]
    private var selectedIndex: Int

    init(titles: [String], selectedIndex: Int) {
        self.titles = titles
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        // Clipping is what hides pills beyond the panel's width until the
        // self-driven scroll reveals them.
        scrollView.clipsToBounds = true
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
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Self.contentInset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Self.contentInset),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let pillWidth = Self.uniformPillWidth(for: titles)
        for (index, title) in titles.enumerated() {
            let pill = PillTabItemView()
            pill.configure(title: title, isSelected: index == selectedIndex)
            pill.onSelected = { [weak self] in self?.handlePillSelected(index) }
            pill.onFocused = { [weak self] coordinator in
                self?.scrollPillToCenter(pill, coordinator: coordinator)
            }
            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: pillWidth).isActive = true
            stack.addArrangedSubview(pill)
            pills.append(pill)
        }
    }

    /// One width for every pill, sized to the widest title so the bar reads as
    /// a consistent row of tabs rather than ragged chips. Measured at `.heavy`
    /// (the active/focused weight) so bolder text never overflows a width
    /// computed from a lighter one. A floor, not a cap — see the header.
    @MainActor
    static func uniformPillWidth(for titles: [String]) -> CGFloat {
        let measuringFont = UIFont.systemFont(ofSize: 20, weight: .heavy)
        let widest = titles
            .map { ceil(($0 as NSString).size(withAttributes: [.font: measuringFont]).width) }
            .max() ?? 0
        return widest + 40
    }

    /// Center-anchored self-driven scroll: the focused pill is pulled toward
    /// the bar's midpoint, clamped at the content edges. Near the ends focus
    /// visibly walks pill-to-pill; in the middle the pills stream under a
    /// stationary focus position, so a partially-visible neighbor always
    /// signals that more tabs exist off-edge.
    private func scrollPillToCenter(_ pill: PillTabItemView, coordinator: UIFocusAnimationCoordinator) {
        let pillFrameInScroll = pill.convert(pill.bounds, to: scrollView)
        let targetX = pillFrameInScroll.midX - scrollView.bounds.width / 2
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let clamped = min(max(0, targetX), maxX)
        guard abs(clamped - scrollView.contentOffset.x) > 0.5 else { return }
        coordinator.addCoordinatedAnimations({
            self.scrollView.contentOffset.x = clamped
        }, completion: nil)
    }

    /// The authoritative veto for horizontal moves (see the header for why a
    /// `pressesBegan` guard cannot do this job).
    ///
    /// From a pill, Left/Right may land on exactly ONE view: the immediately
    /// adjacent pill. Anything else is cancelled — at the ends that is the whole
    /// story (focus holds on the edge pill); in the middle the cancel is followed
    /// by a driven move to the neighbour the engine should have picked.
    ///
    /// The looser "did it leave the pill row?" test this replaces was not
    /// enough on device: Left on the leftmost pill jumped focus clear across
    /// the bar to the last pill. Whatever produced that candidate — a focus
    /// group resolution, a re-resolution after the cancel — naming the one
    /// legal destination refuses it without needing to know.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard context.focusHeading == .left || context.focusHeading == .right else {
            return super.shouldUpdateFocus(in: context)
        }
        guard let previous = context.previouslyFocusedView,
              let fromIndex = pillIndex(containing: previous) else {
            return super.shouldUpdateFocus(in: context)
        }
        let movingLeft = context.focusHeading == .left
        let landing = context.nextFocusedView.flatMap(pillIndex(containing:))
        guard Self.allowsHorizontalMove(from: fromIndex, to: landing,
                                        movingLeft: movingLeft,
                                        pillCount: pills.count) else {
            // Refusing alone is only right at the two ends. In the middle the
            // engine simply aimed somewhere other than the neighbour — this bar
            // scrolls and clips (the Insights panel's tabs overflow its 600pt
            // width; the Info popup's three never do), so a partially-hidden
            // neighbour loses the spatial search to the list below, or to
            // nothing at all. Cancel that and drive the move, or the whole bar
            // dead-ends on whichever pill focus landed on (#288).
            let wanted = fromIndex + (movingLeft ? -1 : 1)
            if pills.indices.contains(wanted) {
                drivenTarget = pills[wanted]
                setNeedsFocusUpdate()
            }
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }

    /// Target for one driven horizontal move — see `shouldUpdateFocus`. Held
    /// until the update lands (cleared in `didUpdateFocus`) because the request
    /// is made from inside an in-flight update, so it resolves a cycle later.
    private var drivenTarget: PillTabItemView?

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        drivenTarget = nil
    }

    /// Whether a horizontal move from pill `fromIndex` may land on pill
    /// `landing` (nil = a view outside the bar). Only the immediately adjacent
    /// pill is legal; at either end nothing is. Pure so it is unit-testable —
    /// `UIFocusUpdateContext` has no public initializer.
    nonisolated static func allowsHorizontalMove(from fromIndex: Int, to landing: Int?, movingLeft: Bool, pillCount: Int) -> Bool {
        let wanted = fromIndex + (movingLeft ? -1 : 1)
        guard wanted >= 0, wanted < pillCount else { return false }
        return landing == wanted
    }

    private func pillIndex(containing view: UIView) -> Int? {
        pills.firstIndex { view === $0 || view.isDescendant(of: $0) }
    }

    private func handlePillSelected(_ index: Int) {
        guard index != selectedIndex else { return }
        selectedIndex = index
        for (pillIndex, pill) in pills.enumerated() {
            pill.configure(title: titles[pillIndex], isSelected: pillIndex == index)
        }
        onSelect?(index)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let drivenTarget { return [drivenTarget] }
        if pills.indices.contains(selectedIndex) { return [pills[selectedIndex]] }
        return pills.first.map { [$0] } ?? []
    }

    /// Whether focus currently sits on one of this bar's pills. Consulted by
    /// `InsightsPanelContainerView.pressesBegan` to decide whether a Down press
    /// should escape back into the list below (the reverse of the Up escape —
    /// the focus engine's own directional search does not reliably cross the
    /// scroll-view boundaries between the two).
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
/// chip while focus is on a different pill. Select (not mere focus) commits the
/// change. Kept as its own type rather than reusing `SeasonPillView` (that
/// type's `focusEnabled` gating and 31pt sizing don't fit this
/// always-focusable, compact bar).
private final class PillTabItemView: UIControl {

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
    /// Invoked whenever this pill takes focus — lets the hosting bar scroll it
    /// into view, since a pill has no awareness of its own scroll container.
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
