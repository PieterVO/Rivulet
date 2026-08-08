// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

@main
struct RivuletiOSApp: App {
    @StateObject private var plex = IOSPlexSession()
    @StateObject private var navigation = IOSNavigationSettings()

    init() {
        #if !DEBUG
        // Deferred and gated exactly like tvOS: the SDK is never started in
        // DEBUG, an empty DSN means Secrets.swift was never filled in locally
        // so there is nothing to start, and the 3s wait keeps the SDK's
        // swizzling and session-tracking cost off the launch path. Trade-off is
        // the same too: a crash inside the first ~3s is not captured.
        Task.detached(priority: .utility) {
            guard !Secrets.sentryDSN.isEmpty else { return }
            try? await Task.sleep(for: .seconds(3))
            await SentryStartup.start(platform: .iOS)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environmentObject(plex)
                .environmentObject(navigation)
        }
    }
}
