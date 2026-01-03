//
//  SettingsView.swift
//  Rivulet
//
//  Main settings screen for tvOS
//

import SwiftUI

// MARK: - Settings Destination

enum SettingsDestination: Hashable {
    case plex
    case iptv
    case libraries
    case cache
}

// MARK: - Autoplay Countdown

enum AutoplayCountdown: Int, CaseIterable, CustomStringConvertible {
    case off = 0
    case fiveSeconds = 5
    case tenSeconds = 10
    case twentySeconds = 20

    var description: String {
        switch self {
        case .off: return "Off"
        case .fiveSeconds: return "5 seconds"
        case .tenSeconds: return "10 seconds"
        case .twentySeconds: return "20 seconds"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @State private var navigationPath = NavigationPath()
    @AppStorage("showHomeHero") private var showHomeHero = false
    @AppStorage("showLibraryHero") private var showLibraryHero = false
    @AppStorage("showLibraryRecommendations") private var showLibraryRecommendations = true
    @AppStorage("liveTVLayout") private var liveTVLayoutRaw = LiveTVLayout.guide.rawValue
    @AppStorage("confirmExitMultiview") private var confirmExitMultiview = true
    @AppStorage("allowFourStreams") private var allowFourStreams = false
    @AppStorage("combineLiveTVSources") private var combineLiveTVSources = true
    @AppStorage("classicTVMode") private var classicTVMode = false
    @AppStorage("showSkipButton") private var showSkipButton = true
    @AppStorage("autoSkipIntro") private var autoSkipIntro = false
    @AppStorage("autoSkipCredits") private var autoSkipCredits = false
    @AppStorage("autoSkipAds") private var autoSkipAds = false
    @AppStorage("highQualityScaling") private var highQualityScaling = true
    @AppStorage("autoplayCountdown") private var autoplayCountdownRaw = AutoplayCountdown.fiveSeconds.rawValue
    @AppStorage("showMarkersOnScrubber") private var showMarkersOnScrubber = true
    @AppStorage("useAVPlayerForDolbyVision") private var useAVPlayerForDolbyVision = false
    @Environment(\.focusScopeManager) private var focusScopeManager
    @Environment(\.nestedNavigationState) private var nestedNavState
    #if os(tvOS)
    @Environment(\.openSidebar) private var openSidebar
    @Environment(\.isSidebarVisible) private var isSidebarVisible
    #endif
    @State private var focusTrigger = 0  // Increment to trigger first row focus

    private var liveTVLayout: Binding<LiveTVLayout> {
        Binding(
            get: { LiveTVLayout(rawValue: liveTVLayoutRaw) ?? .channels },
            set: { liveTVLayoutRaw = $0.rawValue }
        )
    }

    private var autoplayCountdown: Binding<AutoplayCountdown> {
        Binding(
            get: { AutoplayCountdown(rawValue: autoplayCountdownRaw) ?? .fiveSeconds },
            set: { autoplayCountdownRaw = $0.rawValue }
        )
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    // Header
                    Text("Settings")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 80)
                        .padding(.top, 60)

                    // Settings categories
                    VStack(spacing: 24) {
                        // Appearance section
                        SettingsSection(title: "Appearance") {
                            SettingsRow(
                                icon: "sidebar.squares.left",
                                iconColor: .purple,
                                title: "Sidebar Libraries",
                                subtitle: "Show, hide, and reorder libraries",
                                action: {
                                    navigationPath.append(SettingsDestination.libraries)
                                },
                                focusTrigger: focusTrigger  // First row gets focus
                            )

                            SettingsToggleRow(
                                icon: "sparkles.rectangle.stack",
                                iconColor: .indigo,
                                title: "Home Hero",
                                subtitle: "Featured content banner on Home",
                                isOn: $showHomeHero
                            )

                            SettingsToggleRow(
                                icon: "rectangle.stack",
                                iconColor: .teal,
                                title: "Library Hero",
                                subtitle: "Featured content banner in libraries",
                                isOn: $showLibraryHero
                            )

                            SettingsToggleRow(
                                icon: "square.stack.3d.up",
                                iconColor: .cyan,
                                title: "Discovery Rows",
                                subtitle: "Top Rated, Rediscover, and similar",
                                isOn: $showLibraryRecommendations
                            )
                        }

                        // Playback section
                        SettingsSection(title: "Playback") {
                            SettingsToggleRow(
                                icon: "forward.fill",
                                iconColor: .blue,
                                title: "Show Skip Button",
                                subtitle: "Display button to skip intro and credits",
                                isOn: $showSkipButton
                            )

                            SettingsToggleRow(
                                icon: "timeline.selection",
                                iconColor: .yellow,
                                title: "Show Markers on Scrubber",
                                subtitle: "Highlight intro, credits, and ads on the progress bar",
                                isOn: $showMarkersOnScrubber
                            )

                            SettingsToggleRow(
                                icon: "play.circle",
                                iconColor: .green,
                                title: "Auto-Skip Intro",
                                subtitle: "Automatically skip TV show intros",
                                isOn: $autoSkipIntro
                            )

                            SettingsToggleRow(
                                icon: "stop.circle",
                                iconColor: .orange,
                                title: "Auto-Skip Credits",
                                subtitle: "Automatically skip end credits",
                                isOn: $autoSkipCredits
                            )

                            SettingsToggleRow(
                                icon: "forward.frame",
                                iconColor: .red,
                                title: "Auto-Skip Ads",
                                subtitle: "Automatically skip advertisements",
                                isOn: $autoSkipAds
                            )

                            SettingsPickerRow(
                                icon: "forward.end.alt",
                                iconColor: .purple,
                                title: "Autoplay Countdown",
                                subtitle: "Time before next episode plays",
                                selection: autoplayCountdown,
                                options: AutoplayCountdown.allCases
                            )

                            SettingsToggleRow(
                                icon: "sparkles.tv",
                                iconColor: .pink,
                                title: "High Quality Scaling",
                                subtitle: "Sharper upscaling for 720p/1080p content. Maybe you can tell a difference",
                                isOn: $highQualityScaling
                            )

                            SettingsToggleRow(
                                icon: "sparkles.tv",
                                iconColor: .purple,
                                title: "Use AVPlayer for Dolby Vision",
                                subtitle: "DV Profile 5/8 only. Profile 7 (MKV remux) requires MPV",
                                isOn: $useAVPlayerForDolbyVision
                            )
                        }

                        // Live TV section
                        SettingsSection(title: "Live TV") {
                            SettingsToggleRow(
                                icon: "tv.fill",
                                iconColor: .indigo,
                                title: "Classic TV Mode",
                                subtitle: "Hide player controls for a traditional TV experience",
                                isOn: $classicTVMode
                            )

                            SettingsToggleRow(
                                icon: "square.stack.3d.down.right",
                                iconColor: .purple,
                                title: "Combine Sources",
                                subtitle: "Show all sources in one Channels view, or separate sidebar entries",
                                isOn: $combineLiveTVSources
                            )

                            SettingsPickerRow(
                                icon: "tv",
                                iconColor: .green,
                                title: "Default Layout",
                                subtitle: "Choose channel grid or TV guide view",
                                selection: liveTVLayout,
                                options: LiveTVLayout.allCases
                            )

                            SettingsToggleRow(
                                icon: "rectangle.split.2x2",
                                iconColor: .blue,
                                title: "Confirm Exit Multiview",
                                subtitle: "Ask before closing multiple streams",
                                isOn: $confirmExitMultiview
                            )

                            SettingsToggleRow(
                                icon: "rectangle.split.2x2.fill",
                                iconColor: .orange,
                                title: "Allow 3 or 4 Streams",
                                subtitle: "4 streams may crash the app, but I won't stop you",
                                isOn: $allowFourStreams
                            )
                        }

                        // Storage section
                        SettingsSection(title: "Storage") {
                            SettingsRow(
                                icon: "internaldrive",
                                iconColor: .gray,
                                title: "Cache & Storage",
                                subtitle: "Manage cached images and data"
                            ) {
                                navigationPath.append(SettingsDestination.cache)
                            }
                        }

                        // Servers section
                        SettingsSection(title: "Servers") {
                            SettingsRow(
                                icon: "server.rack",
                                iconColor: .orange,
                                title: "Plex Server",
                                subtitle: "Media library connection"
                            ) {
                                navigationPath.append(SettingsDestination.plex)
                            }

                            SettingsRow(
                                icon: "tv.and.mediabox",
                                iconColor: .blue,
                                title: "Live TV Sources",
                                subtitle: "Manage channel sources"
                            ) {
                                navigationPath.append(SettingsDestination.iptv)
                            }
                        }

                        // About section
                        SettingsSection(title: "About") {
                            SettingsInfoRow(title: "App", value: "Rivulet")
                            SettingsInfoRow(title: "Version", value: appVersion)
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.bottom, 80)
                }
            }
            .background(Color.black)
            #if os(tvOS)
            .onMoveCommand { direction in
                // Open sidebar when pressing left at the edge
                guard !isSidebarVisible else { return }
                if direction == .left {
                    openSidebar()
                }
            }
            #endif
            .onAppear {
                // Set initial focus when view first appears
                DispatchQueue.main.async {
                    focusTrigger += 1
                }
            }
            .onChange(of: focusScopeManager.restoreTrigger) { _, _ in
                // Trigger first row to claim focus when sidebar closes
                focusTrigger += 1
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .plex:
                    PlexSettingsView()
                case .iptv:
                    IPTVSettingsView()
                case .libraries:
                    LibrarySettingsView()
                case .cache:
                    CacheSettingsView()
                }
            }
        }
        // Tell parent we're in nested navigation when path is not empty
        .onChange(of: navigationPath.count) { _, newCount in
            let isNested = newCount > 0
            nestedNavState.isNested = isNested
            if isNested {
                nestedNavState.goBackAction = { [weak nestedNavState] in
                    if !navigationPath.isEmpty {
                        navigationPath.removeLast()
                    }
                    if navigationPath.isEmpty {
                        nestedNavState?.isNested = false
                    }
                }
            } else {
                nestedNavState.goBackAction = nil
            }
        }
    }
}

#Preview {
    SettingsView()
}
