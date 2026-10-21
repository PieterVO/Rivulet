// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  A collection that drives its own vertical focus scroll; the engine's drifts. With
//  `isScrollEnabled = false`, the top section pins at `topBand` and every other row
//  centres, clamped to the content, as on Home and Apple's detail page.

import UIKit

final class FocusScrollControlledCollectionView: UICollectionView {
    /// Screen-y the TOP section's row top is pinned to (under the logo + pills).
    var topBand: CGFloat = 230
    /// Duration of the controlled vertical scroll. Defaults to the shared
    /// `FocusScrollMotion.settleDuration` so the home and detail surfaces stay
    /// in sync; still overridable per instance.
    var scrollDuration: TimeInterval = FocusScrollMotion.settleDuration
    /// Fires on every focus change — the newly-focused index path, or nil when
    /// focus leaves the collection. Used to track which episode/season is current.
    var onFocusedIndexPath: ((IndexPath?) -> Void)?

    /// Focus is on the top section, the only one Up lifts to the pills from.
    private(set) var focusedCellIsTopSection = false {
        didSet { if focusedCellIsTopSection && !oldValue { lastTopFocusTime = CACurrentMediaTime() } }
    }
    private var lastTopFocusTime: CFTimeInterval = 0
    /// The engine moves focus onto the episodes about 4 ms before pressesBegan sees the same
    /// Up, so this window keeps that press from also lifting to the pills.
    var topSectionJustTookFocus: Bool { CACurrentMediaTime() - lastTopFocusTime < 0.06 }

    /// Set by the owner per snapshot. A section, not a cell class: trailers reuse `EpisodeCollectionCell`.
    var topSectionIndex: Int?

    /// While a description has focus, every description is focusable for Left/Right;
    /// otherwise they stay gated so Up from below lands on the thumb.
    private(set) var focusedViewIsEpisodeDescription = false
    /// Index path of the focused episode cell (top section), or nil. Used to
    /// redirect Left/Right from a description to the adjacent episode's thumb.
    private(set) var focusedEpisodeIndexPath: IndexPath?

    /// The last focused cell, kept across a modal. Nothing else remembers it here (both
    /// system restores are off on purpose), and it survives focus leaving the collection.
    private(set) var lastFocusedIndexPath: IndexPath?

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let ctx = context as? UICollectionViewFocusUpdateContext
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusedIndexPath?(ctx?.nextFocusedIndexPath)
        focusedViewIsEpisodeDescription = context.nextFocusedView is EpisodeDescriptionView

        // From the focused view: in orthogonal sections nextFocusedIndexPath is nil.
        guard let nextView = context.nextFocusedView,
              nextView.isDescendant(of: self),
              let cell = enclosingCell(of: nextView) else {
            focusedCellIsTopSection = false   // focus left the collection (pills/hero)
            focusedEpisodeIndexPath = nil
            return
        }
        let frame = cell.convert(cell.bounds, to: self)   // content coordinates
        let minY = -adjustedContentInset.top
        let maxY = max(minY, contentSize.height - bounds.height + adjustedContentInset.bottom)
        // A shelf row's focused tile belongs to its nested collection, so resolve the cell this one owns.
        let cellIndexPath = indexPath(for: cell) ?? ownedCell(containing: nextView)?.indexPath
        let isTop = topSectionIndex != nil && cellIndexPath?.section == topSectionIndex
        focusedCellIsTopSection = isTop
        focusedEpisodeIndexPath = isTop ? cellIndexPath : nil
        // The one place the path is resolved for every row shape.
        if let cellIndexPath { lastFocusedIndexPath = cellIndexPath }
        let targetY = isTop ? (frame.minY - topBand) : (frame.midY - bounds.height / 2)
        let clamped = max(minY, min(targetY, maxY))
        animateOffset(to: clamped)
    }

    // MARK: - Per-frame scroll driver

    // UIView.animate jumps the model offset at once, so a row ending off-screen loses its
    // cells before it slides out. Advancing the real offset per frame recycles gradually.
    private var scrollLink: CADisplayLink?
    private var scrollStartY: CGFloat = 0
    private var scrollTargetY: CGFloat = 0
    private var scrollStartTime: CFTimeInterval = 0

    private func animateOffset(to targetY: CGFloat) {
        scrollLink?.invalidate()
        if abs(targetY - contentOffset.y) < 0.5 {
            contentOffset = CGPoint(x: 0, y: targetY)
            scrollLink = nil
            return
        }
        scrollStartY = contentOffset.y          // continue from the current position
        scrollTargetY = targetY
        scrollStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepScroll))
        link.add(to: .main, forMode: .common)
        scrollLink = link
    }

    @objc private func stepScroll(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - scrollStartTime
        let t = scrollDuration > 0 ? min(1, elapsed / scrollDuration) : 1
        let e = FocusScrollMotion.ease(t)   // shared focus-scroll curve (cubic ease-out)
        contentOffset = CGPoint(x: 0, y: scrollStartY + (scrollTargetY - scrollStartY) * CGFloat(e))
        if t >= 1 {
            link.invalidate()
            scrollLink = nil
            contentOffset = CGPoint(x: 0, y: scrollTargetY)
        }
    }

    /// Walk up from a focused view to its enclosing collection-view cell (or nil
    /// if the focus left the collection entirely).
    private func enclosingCell(of view: UIView) -> UICollectionViewCell? {
        var v: UIView? = view
        while let cur = v {
            if let cell = cur as? UICollectionViewCell { return cell }
            if cur === self { return nil }
            v = cur.superview
        }
        return nil
    }

    /// The cell of this collection containing `view`, walking past a shelf row's nested cells.
    func ownedCell(containing view: UIView) -> (cell: UICollectionViewCell, indexPath: IndexPath)? {
        var v: UIView? = view
        while let cur = v, cur !== self {
            if let cell = cur as? UICollectionViewCell, let ip = indexPath(for: cell) {
                return (cell, ip)
            }
            v = cur.superview
        }
        return nil
    }
}
