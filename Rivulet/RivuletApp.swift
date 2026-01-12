//
//  RivuletApp.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import SwiftUI
import SwiftData
import Sentry

@main
struct RivuletApp: App {

    init() {
        SentrySDK.start { options in
            options.dsn = Secrets.sentryDSN
            options.debug = false
            options.tracesSampleRate = 1.0
            options.attachStacktrace = true
            options.enableAutoSessionTracking = true
            options.enableCaptureFailedRequests = true
            options.enableSwizzling = true
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2
        }

        // Initialize Now Playing service early to configure audio session
        Task { @MainActor in
            NowPlayingService.shared.initialize()
        }
    }

    var sharedModelContainer: ModelContainer = {
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
                .preferredColorScheme(.dark)  // Force dark mode
                .onOpenURL { url in
                    // Handle deep links from Top Shelf
                    Task {
                        await DeepLinkHandler.shared.handle(url: url)
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
