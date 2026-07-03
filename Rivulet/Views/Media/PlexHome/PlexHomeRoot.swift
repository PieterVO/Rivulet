//
//  PlexHomeRoot.swift
//  Rivulet
//
//  SwiftUI shell for the Plex Home screen. Wraps the UIKit
//  `PlexHomeViewController` (via `PlexHomeUIKitBridge`) in a
//  NavigationStack so music selections still navigate via SwiftUI's stack
//  to the music routers. Everything else navigates inside UIKit.
//

import SwiftUI

struct PlexHomeRoot: View {
    var body: some View {
        UIKitHomeContainer()
    }
}

/// SwiftUI shell that owns the NavigationStack + music-selection binding
/// for the UIKit home. Media detail navigation happens inside the UIKit
/// controller; only music selections flip the binding here and push the
/// music routers.
///
/// Also mirrors the SwiftUI home's `nestedNavigationState.isNested` plumb:
/// the sidebar reads this flag to hide its tab bar while a detail view is
/// on top.
struct UIKitHomeContainer: View {
    /// Surface to render — .home (default) or .library(key:title:). Library
    /// call sites pass their key/title and `.id(key)` the container so each
    /// library gets a fresh controller.
    var mode: HomeMode = .home
    @State private var selectedMusicItem: PlexMetadata?
    @Environment(\.nestedNavigationState) private var nestedNavState

    var body: some View {
        NavigationStack {
            PlexHomeUIKitBridge(mode: mode, selectedMusicItem: $selectedMusicItem)
                .ignoresSafeArea()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $selectedMusicItem) { meta in
                    switch meta.type {
                    case "artist": MusicSearchDetailRouter(plexMeta: meta, kind: .artist)
                    case "album": MusicSearchDetailRouter(plexMeta: meta, kind: .album)
                    default: EmptyView()
                    }
                }
        }
        .onChange(of: selectedMusicItem) { _, newValue in
            nestedNavState.isNested = newValue != nil
        }
    }
}


/// SwiftUI shell for the UIKit SEARCH surface. The system `.searchable`
/// keyboard owns text entry; the query streams into the hosted
/// `PlexHomeViewController(mode: .search)` which debounces, fetches, and
/// renders prompt/recents, inline states, and grouped result grids. Result
/// taps open the UIKit preview carousel / standalone detail directly from
/// the controller; only MUSIC results route back through this stack
/// (artist/album → MusicSearchDetailRouter push, exactly like the SwiftUI
/// PlexSearchView did).
struct UIKitSearchContainer: View {
    @State private var query = ""
    @State private var submitCount = 0
    @State private var selectedMusicItem: PlexMetadata?
    @Environment(\.nestedNavigationState) private var nestedNavState

    var body: some View {
        NavigationStack {
            PlexHomeUIKitBridge(
                mode: .search,
                selectedMusicItem: $selectedMusicItem,
                searchQuery: query,
                searchSubmitCount: submitCount,
                searchQueryBinding: $query
            )
            // No .ignoresSafeArea() here (unlike the hero surfaces): the
            // system search container reserves the keyboard's region via the
            // safe area — ignoring it slides results up underneath the keys.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selectedMusicItem) { meta in
                switch meta.type {
                case "artist": MusicSearchDetailRouter(plexMeta: meta, kind: .artist)
                case "album": MusicSearchDetailRouter(plexMeta: meta, kind: .album)
                default: EmptyView()
                }
            }
        }
        .searchable(text: $query, prompt: "Search your libraries")
        .onSubmit(of: .search) {
            submitCount += 1
        }
        .onChange(of: selectedMusicItem) { _, newValue in
            nestedNavState.isNested = newValue != nil
        }
    }
}
