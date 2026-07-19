// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InfoScrollView.swift
//  Rivulet
//
//  Scroll surface shared by the player's info sheets (Info tab `CardInfoView`
//  and Advanced tab `CardStatsView`), plus the invisible focusable section
//  wrapper (`InfoSectionView`) that makes it work on a real Siri Remote.
//
//  The scroll view itself is NOT focusable and never pan-scrolls. Each
//  section of a sheet (label + row grid) is wrapped in an `InfoSectionView`,
//  an ordinary focus target with no visible focus treatment. Swipes and edge
//  clicks are then the same thing — focus moves between sections — and this
//  view reveals the newly focused section by driving `contentOffset` itself
//  from `didUpdateFocus` (same self-driven pattern as `InsightsActorView`).
//
//  Why not a single focusable pan-scrolling sheet: a swipe is never an arrow
//  UIPress, it is an indirect touch the focus engine turns into a focus move.
//  A sheet that pan-scrolls swallows every swipe (focus can never escape to
//  the tab bar above), and one that steps on arrow presses instead is dead to
//  swipes entirely — it only ever worked from clickpad edge clicks. Discrete
//  focus targets give the engine real geometry, so the tab bar ↔ content
//  crossings need no press handling at all.
//

import UIKit

/// Invisible focus target wrapping one section of an info sheet (its label +
/// row grid). Carries no focus visuals on purpose — these sheets are
/// read-only, and the feedback is the panel ring plus the reveal scroll.
final class InfoSectionView: UIView {

    private let stack = UIStackView()

    override var canBecomeFocused: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        // Matches the sheet stack's inter-section spacing so the label→grid
        // gap reads identically to the pre-wrapper layout.
        stack.spacing = 16
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Replaces the section's content. The wrapper itself persists across
    /// rebuilds (see `CardStatsView`), so focus on it survives a live tick
    /// that reshuffles rows.
    func setContent(_ views: [UIView]) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        views.forEach { stack.addArrangedSubview($0) }
    }
}

final class InfoScrollView: UIScrollView {

    /// Fires when focus enters/leaves this sheet's sections, so the hosting
    /// panel can brighten its own boundary (the sheet draws no focus ring).
    var onFocusChange: ((Bool) -> Void)?

    /// Breathing room above/below a revealed section so it never sits flush
    /// against the clip edge.
    nonisolated static let revealPadding: CGFloat = 12

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Focus-driven scrolling: the engine's own focus-scroll fights a
        // self-driven offset, and a pan-scrolling sheet swallows the very
        // swipes the focus engine needs (see header). Scroll is driven only
        // from didUpdateFocus below.
        isScrollEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let wasInside = context.previouslyFocusedView.map { $0.isDescendant(of: self) } ?? false
        let isInside = context.nextFocusedView.map { $0.isDescendant(of: self) } ?? false
        if isInside != wasInside {
            if isInside { flashScrollIndicators() }
            onFocusChange?(isInside)
        }
        guard isInside, let next = context.nextFocusedView else { return }
        reveal(sectionContaining: next)
    }

    private func reveal(sectionContaining view: UIView) {
        var candidate: UIView? = view
        while let current = candidate, !(current is InfoSectionView), current !== self {
            candidate = current.superview
        }
        guard let section = candidate as? InfoSectionView else { return }
        let frame = section.convert(section.bounds, to: self)
        let target = Self.revealOffsetY(
            current: contentOffset.y,
            sectionMinY: frame.minY,
            sectionMaxY: frame.maxY,
            viewportHeight: bounds.height,
            contentHeight: contentSize.height
        )
        guard abs(target - contentOffset.y) > 0.5 else { return }
        // Shared focus-scroll duration/curve rather than the focus
        // coordinator's own ~0.2s animation, which reads as an abrupt snap —
        // same choice as InsightsActorView.
        UIView.animate(withDuration: FocusScrollMotion.settleDuration, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.contentOffset.y = target
        }
    }

    /// Target offset that reveals a focused section: minimal movement when
    /// the (padded) section fits the viewport; top-aligned when it is taller
    /// and focus arrives from above, bottom-aligned when focus returns from
    /// below (keeps the reading position); always clamped to the scrollable
    /// range. Pure so it is unit-testable (`InfoSectionRevealTests`).
    nonisolated static func revealOffsetY(
        current: CGFloat,
        sectionMinY: CGFloat,
        sectionMaxY: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat
    ) -> CGFloat {
        let paddedMinY = sectionMinY - revealPadding
        let paddedMaxY = sectionMaxY + revealPadding
        let maxOffset = max(0, contentHeight - viewportHeight)
        let target: CGFloat
        if paddedMaxY - paddedMinY <= viewportHeight {
            // Fits: scroll just enough that the whole section is visible.
            target = min(max(current, paddedMaxY - viewportHeight), paddedMinY)
        } else {
            target = paddedMinY < current ? paddedMaxY - viewportHeight : paddedMinY
        }
        return min(max(0, target), maxOffset)
    }
}
