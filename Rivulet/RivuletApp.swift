// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  RivuletApp.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import SwiftUI
import SwiftData
import Sentry

// MARK: - App

@main
struct RivuletApp: App {
    init() {
        StartupTimer.arm()
        StartupTimer.mark("RivuletApp.init")
        // Default the Home hero ON for fresh installs (and any user who hasn't
        // explicitly toggled it). The home reads this via UserDefaults.bool(),
        // which returns false for an unset key, so register the default here
        // before any read. An explicit user choice still wins.
        UserDefaults.standard.register(defaults: ["showHomeHero": true])
        // Start the path monitor now; its first reading arrives after a delay.
        _ = NetworkPathMonitor.shared

        // PlexAuthManager owns identity and lives in RivuletCore; the content
        // store it hands off to is per platform. Set BEFORE any sign-in can
        // run: without the first hook the sidebar's conditional TabSection
        // latches to "empty" on a fresh sign-in, and without the second, a
        // sign-out leaves the previous server's hubs on screen.
        PlexAuthManager.onAuthenticated = { await PlexDataStore.shared.loadLibrariesIfNeeded() }
        PlexAuthManager.onSignedOut = {
            MusicQueue.shared.stop()
            MusicQueue.shared.clear()
            PlexDataStore.shared.reset()
            // Older builds recorded token-bearing URLs in the cache metadata.
            Task { await ImageCacheManager.shared.clearAll() }
        }
        JellyfinSession.onChanged = { JellyfinDataStore.shared.reload() }
        PlexLiveTimelineKeepalive.releaseOtherSession = { JellyfinLiveTVProvider.closeLiveStream($0) }
        PlexUserProfileManager.onProfileChanged = {
            // The queue reports progress with whichever token is current.
            MusicQueue.shared.stop()
            MusicQueue.shared.clear()
            await PlexDataStore.shared.onProfileSwitched()
            // A restricted profile does not see the Jellyfin server.
            JellyfinDataStore.shared.reload()
        }
        PlexUserProfileManager.onInitialProfileSelected = {
            LibrarySettingsManager.shared.onProfileSwitched()
            JellyfinDataStore.shared.reload()
        }

        #if !DEBUG
        // Sentry starts 3 s after launch: in init() its uploads beat the network
        // (`NECP [22]`, `-1000 bad URL`) and its swizzling cost the launch. A crash before then is lost.
        Task.detached(priority: .utility) {
            // No DSN (Secrets.swift is local): skip Sentry so SentryBridge calls no-op.
            guard !Secrets.sentryDSN.isEmpty else { return }
            try? await Task.sleep(for: .seconds(3))
            await Self.startSentry()
        }
        #endif

        // NowPlayingService disabled — AVPlayerViewController handles Now Playing natively.
        // NowPlayingService.shared.initialize()

        // Emit the AppLaunch perf event so launch time, memory, and scroll
        // smoothness can be correlated in Instruments traces.
        Task { @MainActor in
            Perf.event(.appLaunch, message: "init")
        }
    }

    #if !DEBUG
    /// Starts Sentry. MUST be main-actor isolated: `SentrySDK.start` builds the
    /// SDK's dependency container, which reads `UIApplication.applicationState`
    /// and installs swizzling + session / app-hang tracking. Called from the
    /// deferred `Task.detached` above it tripped the Main Thread Checker twice on
    /// every device launch ("UI API called on a background thread"). Only the
    /// start call is hoisted — the 3s deferral that keeps launch logs clean stays.
    @MainActor
    private static func startSentry() {
        SentryStartup.start(platform: .tvOS)

        // Seed the App Hang triage scope so the very first hang event after
        // launch already carries a screen tag. Updated thereafter via
        // AppHangContext as the user navigates and plays. See RIVULET-41.
        // Already on the main actor here, so no hop.
        AppHangContext.setScreen("launch")
    }
    #endif

    var sharedModelContainer: ModelContainer = {
        // Runs before init()'s body, so this is the earliest app code at launch.
        // Opening a 7-model store is not free.
        StartupTimer.mark("sharedModelContainer build start")
        defer { StartupTimer.mark("sharedModelContainer build end") }
        let schema = Schema([
            ServerConfiguration.self,
            PlexServer.self,
            IPTVSource.self,
            Channel.self,
            FavoriteChannel.self,
            WatchProgress.self,
            EPGProgram.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(MediaProviderRegistry.shared)
                .environment(MetadataSourceRegistry.shared)
                // A scene-based app gets URLs and activities here; UIKit never
                // calls the app delegate's open-URL methods for it.
                .onOpenURL { DeepLinkHandler.shared.handle(url: $0) }
                .onContinueUserActivity("com.rivulet.viewMedia") { activity in
                    guard let key = activity.userInfo?["ratingKey"] as? String, !key.isEmpty else { return }
                    DeepLinkHandler.shared.handleDetail(ratingKey: key)
                }
                .onContinueUserActivity("com.rivulet.playMedia") { activity in
                    guard let key = activity.userInfo?["ratingKey"] as? String, !key.isEmpty else { return }
                    DeepLinkHandler.shared.handlePlay(ratingKey: key)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
