// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  A collection view whose horizontal contentOffset can be pinned. `setCollectionViewLayout`
//  zeroes the offset later and repeatedly, without consulting `targetContentOffset`, which
//  throws a non-first expanded cell off screen; the pin holds from expand to collapse.

import UIKit

final class PinnableCollectionView: UICollectionView {
    /// When non-nil, the horizontal contentOffset is forced to this value on
    /// every write. nil = normal (paging) behavior.
    var pinnedOffsetX: CGFloat? {
        didSet {
            guard let x = pinnedOffsetX, super.contentOffset.x != x else { return }
            super.contentOffset = CGPoint(x: x, y: super.contentOffset.y)
        }
    }

    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            if let x = pinnedOffsetX {
                super.contentOffset = CGPoint(x: x, y: newValue.y)
            } else {
                super.contentOffset = newValue
            }
        }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if let x = pinnedOffsetX {
            super.setContentOffset(CGPoint(x: x, y: contentOffset.y), animated: false)
        } else {
            super.setContentOffset(contentOffset, animated: animated)
        }
    }
}
