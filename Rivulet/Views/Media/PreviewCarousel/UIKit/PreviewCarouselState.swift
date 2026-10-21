// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  Preview carousel geometry. The card shell follows Apple's TV app (read from its
//  binary, tvOS 26.5); see Docs/PREVIEW_CAROUSEL_REFERENCE_LAYOUT.md.

import UIKit

/// Constants that govern the preview carousel layout. Card shell values
/// are Apple's own; change them only against a fresh reading.
enum PreviewCarouselGeometry {
    /// Distance from the top of the screen to the top edge of each card.
    static let topInset: CGFloat = 40

    /// Card corner radius. Applied to the center slot, the side
    /// peeks, and the expanded hero (which lerps to 0 as it grows
    /// into the fullscreen detail surface).
    static let cornerRadius: CGFloat = 36

    /// Horizontal inset used to compute the centered card's frame.
    /// `centeredFrame.width = screenWidth - 2 * centeredHorizontalInset`.
    static let centeredHorizontalInset: CGFloat = 120

    /// Gap between the centered card and either side peek.
    static let sideCardGap: CGFloat = 20

    /// Share of a card's travel its artwork counter-shifts inside the window,
    /// so the art moves at about a fifth of the card's speed on screen.
    static let parallaxFactor: CGFloat = 0.8

    /// Black dim over a card, scaled by its distance from centre (0 centred,
    /// about 0.76 on a resting neighbour).
    static let neighbourDimAlpha: CGFloat = 0.8

    /// Travel (in normalized position) over which a card's chrome fades out
    /// as it pages away from centre.
    static let contentFadeDistance: CGFloat = 0.3

    /// Card position relative to the viewport centre, -1...1 (0 centred,
    /// about 0.95 on a resting neighbour). Drives parallax, dim and hairline.
    static func normalizedPosition(cardMidX: CGFloat, cardWidth: CGFloat, in bounds: CGRect) -> CGFloat {
        let reach = (bounds.width + cardWidth) / 2
        guard reach > 0 else { return 0 }
        return max(-1, min(1, (cardMidX - bounds.midX) / reach * 1.005))
    }

    /// Horizontal inset applied to the chrome content (logo / metadata
    /// / action row) inside the card: card 120 + 40 puts the metadata left
    /// edge at screen-x 160.
    static let carouselChromeInset: CGFloat = 40
    /// That edge in screen space (160): the collapsed card's content margin.
    static var collapsedChromeInset: CGFloat { centeredHorizontalInset + carouselChromeInset }
    /// The expanded detail's content margin, the app-wide `rowLeading`. The expand
    /// morph's pull derives from it (`ExpandedDetailContainerView.belowFoldExpandPull`).
    static var expandedChromeInset: CGFloat { MediaRowMetrics.rowLeading }

    /// Both the chrome's bottom inset and the below-fold peek height, so the two move
    /// together. Apple's: 75 below the buttons plus a 40 peek (banner 1040 of 1080).
    static let carouselChromeShelfPeek: CGFloat = 115

    /// Duration of the expand/collapse morph (ease-in-out). Card frame,
    /// chrome insets, corner radius and hairline all run on this curve.
    static let expandAnimationDuration: TimeInterval = 0.25

    /// Inset left, right and top, bleeding off the screen bottom as Apple's does
    /// (`Docs/atv_ref/carousel_ref.md`). Not an aspect height: the artwork aspect-fills and crops.
    static func centeredCardSize(in bounds: CGRect) -> CGSize {
        let width = max(0, bounds.width - 2 * centeredHorizontalInset)
        let height = max(0, bounds.height - topInset)
        return CGSize(width: width, height: height)
    }

    static func centeredCardFrame(in bounds: CGRect) -> CGRect {
        let size = centeredCardSize(in: bounds)
        return CGRect(
            x: centeredHorizontalInset,
            y: topInset,
            width: size.width,
            height: size.height
        )
    }
}
