//
//  EpisodeSummaryOverlay.swift
//  Rivulet
//
//  Post-video overlay for TV episodes showing next episode info and autoplay countdown
//

import SwiftUI

struct EpisodeSummaryOverlay: View {
    @ObservedObject var viewModel: UniversalPlayerViewModel
    @ObservedObject var focusScopeManager: FocusScopeManager
    @Environment(\.dismiss) private var dismiss

    private var hasNextEpisode: Bool {
        viewModel.nextEpisode != nil
    }

    private var countdownActive: Bool {
        viewModel.countdownSeconds > 0 && !viewModel.isCountdownPaused
    }

    private var autoplayEnabled: Bool {
        // Default to enabled (5 seconds) if key doesn't exist
        if UserDefaults.standard.object(forKey: "autoplayCountdown") == nil {
            return true
        }
        return UserDefaults.standard.integer(forKey: "autoplayCountdown") > 0
    }

    private var isActive: Bool {
        focusScopeManager.isScopeActive(.postVideo)
    }

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Main content area - centered
                VStack(spacing: 32) {
                    // Header
                    if hasNextEpisode {
                        Text("Up Next")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        VStack(spacing: 8) {
                            Text("End of Series")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(.white)

                            Text("You've watched all available episodes")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }

                    // Next episode card
                    if let nextEpisode = viewModel.nextEpisode {
                        NextEpisodeCard(
                            episode: nextEpisode,
                            serverURL: viewModel.serverURL,
                            authToken: viewModel.authToken
                        )
                        .frame(maxWidth: 700)
                    }

                    // Countdown and buttons
                    HStack(spacing: 40) {
                        if hasNextEpisode {
                            // Countdown ring (only if autoplay enabled)
                            if autoplayEnabled && countdownActive {
                                CountdownRing(
                                    totalSeconds: UserDefaults.standard.integer(forKey: "autoplayCountdown"),
                                    remainingSeconds: viewModel.countdownSeconds,
                                    isPaused: viewModel.isCountdownPaused
                                )
                            }

                            // Play Next button
                            PostVideoButton(
                                title: countdownActive ? "Play Now" : "Play Next",
                                icon: "play.fill",
                                isPrimary: true,
                                isActive: isActive
                            ) {
                                Task { await viewModel.playNextEpisode() }
                            }

                            // Cancel button (only if countdown active)
                            if countdownActive {
                                PostVideoButton(
                                    title: "Cancel",
                                    icon: nil,
                                    isPrimary: false,
                                    isActive: isActive
                                ) {
                                    viewModel.cancelCountdown()
                                }
                            }
                        }

                        // Close button (always available, especially for end of series)
                        if !hasNextEpisode || !countdownActive {
                            PostVideoButton(
                                title: "Close",
                                icon: "xmark",
                                isPrimary: false,
                                isActive: isActive
                            ) {
                                viewModel.dismissPostVideo()
                                dismiss()
                            }
                        }
                    }

                    // Navigation buttons (Go to Season / Go to Show)
                    HStack(spacing: 24) {
                        if viewModel.metadata.parentRatingKey != nil {
                            PostVideoButton(
                                title: "Go to Season",
                                icon: "list.number",
                                isPrimary: false,
                                isActive: isActive
                            ) {
                                viewModel.navigateToSeason()
                                dismiss()
                            }
                        }

                        if viewModel.metadata.grandparentRatingKey != nil {
                            PostVideoButton(
                                title: "Go to Show",
                                icon: "tv",
                                isPrimary: false,
                                isActive: isActive
                            ) {
                                viewModel.navigateToShow()
                                dismiss()
                            }
                        }
                    }

                    // Episode summary
                    if let summary = viewModel.metadata.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("About This Episode")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))

                            Text(summary)
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: 800, alignment: .leading)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 80)

                Spacer()
            }
        }
        #if os(tvOS)
        .onExitCommand {
            viewModel.dismissPostVideo()
            dismiss()
        }
        .onPlayPauseCommand {
            if hasNextEpisode {
                Task { await viewModel.playNextEpisode() }
            }
        }
        #endif
    }
}

// MARK: - Post Video Button

struct PostVideoButton: View {
    let title: String
    let icon: String?
    let isPrimary: Bool
    let isActive: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: isPrimary ? 22 : 18, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: isPrimary ? 24 : 22, weight: isPrimary ? .semibold : .medium))
            }
            .foregroundStyle(isPrimary ? .black : .white)
            .padding(.horizontal, isPrimary ? 32 : 28)
            .padding(.vertical, isPrimary ? 16 : 14)
            .background(
                Capsule()
                    .fill(buttonBackground)
            )
            .overlay(
                Capsule()
                    .strokeBorder(buttonBorder, lineWidth: isFocused ? 3 : 1)
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
        }
        #if os(tvOS)
        .buttonStyle(CardButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
        .focusable(isActive)
        .focused($isFocused)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    private var buttonBackground: some ShapeStyle {
        if isPrimary {
            return AnyShapeStyle(isFocused ? Color.blue : Color.white)
        } else {
            return AnyShapeStyle(isFocused ? Color.white.opacity(0.3) : Color.white.opacity(0.15))
        }
    }

    private var buttonBorder: Color {
        if isPrimary {
            return isFocused ? .white : .clear
        } else {
            return isFocused ? .white.opacity(0.8) : .white.opacity(0.3)
        }
    }
}

#Preview {
    EpisodeSummaryOverlay(
        viewModel: {
            let vm = UniversalPlayerViewModel(
                metadata: PlexMetadata(ratingKey: "1", type: "episode", title: "Test Episode"),
                serverURL: "http://localhost:32400",
                authToken: "test"
            )
            return vm
        }(),
        focusScopeManager: FocusScopeManager()
    )
}
