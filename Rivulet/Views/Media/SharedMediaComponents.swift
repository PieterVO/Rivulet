//
//  SharedMediaComponents.swift
//  Rivulet
//
//  Small shared SwiftUI helpers used across the surviving SwiftUI surfaces
//  (MediaDetailView, Music, post-video overlays). Extracted from the retired
//  MediaPosterCard.swift when the SwiftUI poster/row/grid views were removed
//  in favor of their UIKit equivalents.
//

import SwiftUI

// MARK: - Card Button Style (tvOS - minimal, no focus ring)

/// A minimal button style that removes the default tvOS focus ring.
/// Hover effect is applied directly to the artwork inside the card.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Watched Corner Tag

/// A rounded-rectangle badge indicating the item has been watched.
/// Sits inside the top-trailing corner of artwork with a dark
/// translucent fill and a white checkmark.
struct WatchedCornerTag: View {
    var cornerRadius: CGFloat = ScaledDimensions.posterCornerRadius

    private let size: CGFloat = 44
    private let checkSize: CGFloat = 20

    var body: some View {
        UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: 0,
                bottomLeading: cornerRadius,
                bottomTrailing: 0,
                topTrailing: 0
            ),
            style: .continuous
        )
        .fill(.black.opacity(0.55))
        .frame(width: size, height: size)
        .overlay {
            Image(systemName: "checkmark")
                .font(.system(size: checkSize, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
