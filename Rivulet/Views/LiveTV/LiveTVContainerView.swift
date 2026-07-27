// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVContainerView.swift
//  Rivulet
//
//  Container view that switches between Channel Layout and Guide Layout
//  based on user settings
//

import SwiftUI

// MARK: - Live TV Layout Option

enum LiveTVLayout: String, CaseIterable, CustomStringConvertible {
    case channels = "Channels"
    case guide = "Guide"

    var description: String { rawValue }
}

// MARK: - Live TV Container View

struct LiveTVContainerView: View {
    /// Optional source ID to filter channels. nil = show all sources.
    var sourceIdFilter: String?

    @AppStorage("liveTVLayout") private var liveTVLayoutRaw = "Guide"
    @StateObject private var dataStore = LiveTVDataStore.shared

    private var layout: LiveTVLayout {
        LiveTVLayout(rawValue: liveTVLayoutRaw) ?? .guide
    }

    var body: some View {
        Group {
            switch layout {
            case .channels:
                ChannelListView(sourceIdFilter: sourceIdFilter)
            case .guide:
                GuideLayoutView(sourceIdFilter: sourceIdFilter)
            }
        }
        .task {
            // Elevate EPG loading priority when user visits Live TV
            await dataStore.elevatePreloadPriority()
            // ...and re-fetch when what we already have has gone stale (older
            // than 30 minutes, or a window that no longer covers now). Both
            // layouts below only load when their data is EMPTY, so without
            // this a returning visit keeps showing an outdated — or
            // entirely past-dated, hence blank — grid.
            await dataStore.refreshIfStale()
        }
    }
}

#Preview {
    LiveTVContainerView()
}
