//
//  GlassRowStyle.swift
//  Rivulet
//
//  Unified tvOS 26 liquid glass styling for list rows
//  Provides consistent focus behavior across the app
//

import SwiftUI


// MARK: - App Store Button Style

/// A button style matching tvOS App Store buttons.
/// Features: white background + black text on focus, glass when unfocused, larger scale effect.
/// Use for standalone buttons like Refresh, Retry, Try Again.
struct AppStoreButtonStyle: ButtonStyle {
    @FocusState private var isFocused: Bool
    var cornerRadius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? .black : .white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isFocused ? .white : .white.opacity(0.15))
            )
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .focused($isFocused)
            .hoverEffectDisabled()
            .focusEffectDisabled()
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
            .animation(.spring(response: 0.15, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

// MARK: - App Store Action Button Style

/// A button style for inline action buttons (Play, Shuffle, etc.) on detail views.
/// Requires external focus state to be passed in since ButtonStyle can't track focus internally.
/// The content is expected to handle its own sizing via .frame() or .padding().
struct AppStoreActionButtonStyle: ButtonStyle {
    var isFocused: Bool
    var cornerRadius: CGFloat = 16
    /// Use true for primary actions (Play), false for secondary (Shuffle, Restart)
    var isPrimary: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? .black : .white)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isFocused ? .white : (isPrimary ? .white.opacity(0.2) : .white.opacity(0.12)))
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(isFocused ? 0 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isFocused ? .clear : .white.opacity(0.2), lineWidth: 0.5)
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .hoverEffectDisabled()
            .focusEffectDisabled()
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
            .animation(.spring(response: 0.15, dampingFraction: 0.9), value: configuration.isPressed)
    }
}
