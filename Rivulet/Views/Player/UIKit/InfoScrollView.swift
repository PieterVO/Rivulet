// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InfoScrollView.swift
//  Rivulet
//
//  Scroll surface shared by the player's info sheets (Info tab `CardInfoView`
//  and Advanced tab `CardStatsView`), plus the invisible focusable row
//  wrapper (`InfoFocusRowView`) that makes it work on a real Siri Remote.
//
//  The scroll view itself is NOT focusable and never pan-scrolls. Each two-up
//  ROW of a sheet is wrapped in an `InfoFocusRowView`, an ordinary focus target
//  with no visible focus treatment. Swipes and edge clicks are then the same
//  thing — focus moves between rows — and this view reveals the newly focused
//  row by driving `contentOffset` itself from `didUpdateFocus` (same
//  self-driven pattern as `InsightsActorView`).
//
//  Why not a single focusable pan-scrolling sheet: a swipe is never an arrow
//  UIPress, it is an indirect touch the focus engine turns into a focus move.
//  A sheet that pan-scrolls swallows every swipe (focus can never escape to
//  the tab bar above), and one that steps on arrow presses instead is dead to
//  swipes entirely — it only ever worked from clickpad edge clicks. Discrete
//  focus targets give the engine real geometry, so the tab bar ↔ content
//  crossings need no press handling at all.
//
//  Focus targets alone can't reach every pixel, though: a row whose text wraps
//  to more lines than the viewport has no focus target in its lower half, so
//  nothing reveals it (issue #242, which bit far harder when the targets were
//  whole sections). Rows stay the primary mechanism and arrow presses are a
//  SUPPLEMENT, handled here on the responder chain above the focused row: when
//  the engine has somewhere to move focus it consumes the press first and this
//  never runs; only a press the engine declined (end of travel, or inside an
//  over-tall row) reaches us, and then we step the offset ourselves.
//

import UIKit
import os

/// TEMP diagnostic instrumentation — see the matching note in
/// `PlayerInfoTabsView.swift`. Remove once the "can't move Down into the
/// tab's content" report is confirmed and fixed from a captured log.
private let infoTabLog = Logger(subsystem: "com.rivulet.app", category: "PlayerInfoTab")

/// Invisible focus target wrapping ONE two-up row of an info sheet. Carries no
/// focus visuals on purpose — these sheets are read-only, and the feedback is
/// the panel ring plus the reveal scroll.
///
/// Granularity is the whole point. This used to wrap a whole SECTION (label +
/// its entire row grid), which gave a sheet only ~4 focus targets, each
/// possibly taller than the panel. A `UIScrollView` clips, and **a clipped view
/// cannot be focused**, so everything past the first tall section had no
/// reachable target and Down did nothing. Arrow presses were patched around
/// that (`pressesBegan` below), but swipes never emit arrow presses — they are
/// indirect touches the focus engine turns into focus moves — so on a Siri
/// Remote the sheet simply dead-ended. One target per ROW keeps the next target
/// always within reach, which is what makes the Insights/trivia panel work.
///
/// The wrapper persists across rebuilds (see `CardStatsView`, which keeps a
/// pool of these and only ever swaps the labels inside them), so focus survives
/// a live tick that reshuffles which rows are present.
final class InfoFocusRowView: UIView {

    private let stack = UIStackView()

    override var canBecomeFocused: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Two equal columns, top-aligned — the geometry the sheets' two-column
        // grid used to build inline, now owned here so every row is identical.
        stack.axis = .horizontal
        stack.spacing = 20
        stack.distribution = .fillEqually
        stack.alignment = .top
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

    /// Puts `left` (and `right`, or an empty spacer so a lone final row stays a
    /// half-width left column) into this row. Re-parents the passed views; the
    /// row itself — the focus target — is never torn down.
    func setPair(_ left: UIView, _ right: UIView?) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        stack.addArrangedSubview(left)
        stack.addArrangedSubview(right ?? UIView())
    }
}

final class InfoScrollView: UIScrollView {

    /// Fires when focus enters/leaves this sheet's sections, so the hosting
    /// panel can brighten its own boundary (the sheet draws no focus ring).
    var onFocusChange: ((Bool) -> Void)?

    /// Breathing room above/below a revealed section so it never sits flush
    /// against the clip edge.
    nonisolated static let revealPadding: CGFloat = 12

    /// How far one declined arrow press nudges the sheet. Deliberately less
    /// than a viewport so the reader keeps an overlap line between steps.
    nonisolated static let pressStep: CGFloat = 240

    /// Window after a focus move inside the sheet during which an arrow press
    /// is assumed to BE that move. tvOS fires `didUpdateFocus` a few ms before
    /// the `pressesBegan` for the same press, so without this gate every
    /// section hop would also step the offset and overshoot (the same-press
    /// race that bites directional handlers generally).
    private static let samePressWindow: CFTimeInterval = 0.2

    private var lastFocusMoveTime: CFTimeInterval = -.greatestFiniteMagnitude

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Focus-driven scrolling: the engine's own focus-scroll fights a
        // self-driven offset, and a pan-scrolling sheet swallows the very
        // swipes the focus engine needs (see header). Scroll is driven from
        // didUpdateFocus below, plus the declined-press fallback in
        // pressesBegan for content no focus target can reach.
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
            infoTabLog.notice("InfoScrollView focus \(isInside ? "ENTERED" : "LEFT"): next=\(String(describing: context.nextFocusedView))")
            if isInside { flashScrollIndicators() }
            onFocusChange?(isInside)
        }
        guard isInside, let next = context.nextFocusedView else { return }
        lastFocusMoveTime = CACurrentMediaTime()
        reveal(rowContaining: next)
    }

    // MARK: - Declined-press scrolling

    /// Steps the offset for an arrow press the focus engine declined. This
    /// override sits on the responder chain ABOVE the focused section, so a
    /// press that did move focus has already been acted on by the engine —
    /// `lastFocusMoveTime` detects that case and leaves the offset to
    /// `reveal(sectionContaining:)`. What is left is exactly the content no
    /// focus target can reach: the interior of a section taller than the
    /// viewport, and the tail below the last section.
    ///
    /// Swipes never produce an arrow press, so this adds nothing for them and
    /// (crucially) takes nothing away — the section hops they rely on are
    /// untouched. Up is not swallowed at the top edge: the tab bar sits above
    /// and must stay reachable.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            let delta: CGFloat
            switch press.type {
            case .upArrow: delta = -Self.pressStep
            case .downArrow: delta = Self.pressStep
            default: continue
            }
            if step(by: delta) { return }
        }
        super.pressesBegan(presses, with: event)
    }

    /// Moves `contentOffset.y` by `delta`, clamped to the scrollable range.
    /// Returns false — leaving the press to bubble — when the engine just
    /// moved focus for this same press, or when there is nowhere to scroll.
    private func step(by delta: CGFloat) -> Bool {
        guard CACurrentMediaTime() - lastFocusMoveTime > Self.samePressWindow else { return false }
        let target = Self.steppedOffsetY(
            current: contentOffset.y,
            delta: delta,
            viewportHeight: bounds.height,
            contentHeight: contentSize.height
        )
        guard abs(target - contentOffset.y) > 0.5 else { return false }
        UIView.animate(withDuration: FocusScrollMotion.settleDuration, delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.contentOffset.y = target
        }
        return true
    }

    private func reveal(rowContaining view: UIView) {
        var candidate: UIView? = view
        while let current = candidate, !(current is InfoFocusRowView), current !== self {
            candidate = current.superview
        }
        guard let section = candidate as? InfoFocusRowView else { return }
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

    /// Target offset for a declined arrow press: the current offset moved by
    /// `delta` and clamped to the scrollable range (which is empty when the
    /// content fits, so a short sheet never moves). Pure so it is
    /// unit-testable alongside `revealOffsetY`.
    nonisolated static func steppedOffsetY(
        current: CGFloat,
        delta: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat
    ) -> CGFloat {
        let maxOffset = max(0, contentHeight - viewportHeight)
        return min(max(0, current + delta), maxOffset)
    }
}
