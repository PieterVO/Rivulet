// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SearchContainerViewController.swift
//  Rivulet
//
//  The Search tab. `UISearchContainerViewController` owns a UISearchController
//  whose `searchResultsController` is `PlexHomeViewController(mode: .search)`,
//  so the keyboard and the results live in ONE focus hierarchy.
//
//  This replaced the SwiftUI `.searchable` shell, which could not hand focus
//  off at all: a Down press from the keyboard reached the root view controller
//  unhandled and the engine produced no focus update, because the results were
//  on the far side of the search presentation's focus boundary. Submit appeared
//  to work only because dismissing the keyboard tore that environment down and
//  focus fell through to the content underneath. Do not reintroduce
//  `.searchable` here; it is not a styling choice, it is the bug.
//
//  It lives outside `UIKit/` on purpose: the music hand-off hosts a SwiftUI
//  detail, and `Views/**/UIKit/**` is the path the no-SwiftUI lint rule scans.
//

import SwiftUI
import UIKit
import os

/// Temporary; paired with the SearchFocus probes in RootShellViewController.
private let searchProbeLog = Logger(subsystem: "com.rivulet.app", category: "SearchFocus")

final class SearchContainerViewController: UIViewController {
    /// The results surface. Also the whole visible page: prompt/recents when
    /// the query is empty, inline states, and the grouped result grids.
    private let results = PlexHomeViewController(mode: .search)
    private let searchController: UISearchController
    private let searchContainer: UISearchContainerViewController

    /// Reports whether a music detail is covering the page, so the shell can
    /// treat Search the way it treats any nested navigation.
    ///
    /// Always delivered async: the reader is SwiftUI observable state, and both
    /// call sites can run inside a SwiftUI update (`viewDidAppear` fires from
    /// `mountContent`, which the representable drives), which is "Publishing
    /// changes from within view updates is not allowed".
    var onNestedChange: ((Bool) -> Void)?

    private func reportNested(_ isNested: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onNestedChange?(isNested) }
    }

    init() {
        searchController = UISearchController(searchResultsController: results)
        searchContainer = UISearchContainerViewController(searchController: searchController)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()

        searchController.searchResultsUpdater = self
        searchController.searchBar.delegate = self
        searchController.searchBar.placeholder = "Search your libraries"
        // Both of these are about OCCLUSION, not appearance.
        //
        // `obscuresBackgroundDuringPresentation` defaults to true and puts a
        // dimming view over the results controller until the search controller
        // decides to show it. The focus engine excludes visually occluded
        // items, so every cell underneath was unfocusable and Down off the
        // keyboard produced no focus update at all — UIFocusDebugger reported
        // it verbatim: "The item is being visually occluded". It only appeared
        // to work after a search because that is when the dimming view goes.
        //
        // Our results controller IS the page — prompt, recents, inline states
        // and grids — so it must be visible from the moment the tab mounts,
        // empty query included. (`showsSearchResultsController` is unavailable
        // on tvOS; clearing the obscuring view is the whole fix here.)
        searchController.obscuresBackgroundDuringPresentation = false

        // A recents pill sets the query from inside the results controller;
        // mirror it back into the field so the two never disagree.
        results.onSearchQueryChangedByController = { [weak self] query in
            guard let self, self.searchController.searchBar.text != query else { return }
            self.searchController.searchBar.text = query
        }
        // Search is the ONLY surface that fires this — home, discover and
        // library never route a music tap through it.
        results.onSelectMusic = { [weak self] meta in
            self?.presentMusicDetail(meta)
        }

        addChild(searchContainer)
        searchContainer.view.frame = view.bounds
        searchContainer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(searchContainer.view)
        searchContainer.didMove(toParent: self)
    }


    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [searchContainer]
    }

    // MARK: - Music hand-off

    /// Artists and albums open the SwiftUI music detail; tracks play directly
    /// and are intercepted in the results controller, never reaching here.
    private func presentMusicDetail(_ meta: PlexMetadata) {
        let kind: MusicSearchDetailRouter.Kind
        switch meta.type {
        case "artist": kind = .artist
        case "album": kind = .album
        default: return
        }

        // The stack is what the pushed album/artist detail navigates within, so
        // Menu inside it pops as it always did. `onExitCommand` sits on the
        // ROOT view only, so it fires just when there is nothing left to pop.
        let root = NavigationStack {
            MusicSearchDetailRouter(plexMeta: meta, kind: kind)
                .onExitCommand { [weak self] in
                    self?.dismiss(animated: true)
                }
        }
        .environment(MusicProviderRegistry.shared)

        let host = UIHostingController(rootView: root)
        host.modalPresentationStyle = .fullScreen
        reportNested(true)
        present(host, animated: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presentedViewController == nil { reportNested(false) }
    }

    /// Temporary probe: sample the results page on every vertical press, so
    /// the log says what was reachable at the moment the press was made rather
    /// than whenever a snapshot last happened to be recomputed.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .upArrow || $0.type == .downArrow }) {
            searchProbeLog.error(
                "results \(self.results.searchFocusDebugState(), privacy: .public)")
            // UIFocusDebugger answers directly what I have been inferring:
            // whether the engine considers the cell focusable, and what a move
            // from the currently focused item would actually do.
            let system = UIFocusSystem.focusSystem(for: view)
            let focused = system?.focusedItem
            let sameSystem = system === results.debugFocusSystem
            searchProbeLog.error("SYSTEM sameAsResults=\(sameSystem, privacy: .public)")
            if let cell = results.debugFirstVisibleCell {
                searchProbeLog.error(
                    "FOCUSABILITY \(String(describing: UIFocusDebugger.checkFocusability(for: cell)), privacy: .public)")
                searchProbeLog.error(
                    "OCCLUDERS \(Self.occluders(of: cell), privacy: .public)")
            }
            if let focused {
                searchProbeLog.error(
                    "SIMULATE \(String(describing: UIFocusDebugger.simulateFocusUpdateRequest(from: focused)), privacy: .public)")
            }
        }
        super.pressesBegan(presses, with: event)
    }
}

// MARK: - Temporary tree probe

private extension SearchContainerViewController {
    static func backing(_ item: UIFocusEnvironment?) -> UIView? {
        var env = item
        while let current = env {
            if let view = current as? UIView { return view }
            if let controller = current as? UIViewController { return controller.viewIfLoaded }
            env = current.parentFocusEnvironment
        }
        return nil
    }

    /// Every view painted ON TOP of `view`: at each level of the superview
    /// chain, the siblings that come after it in `subviews`. Pointers included
    /// so the culprit can be matched against the address UIFocusDebugger
    /// reports for "visually occluded by".
    static func occluders(of view: UIView?) -> String {
        guard var node = view else { return "nil" }
        var out: [String] = []
        while let parent = node.superview {
            if let index = parent.subviews.firstIndex(of: node) {
                for sibling in parent.subviews[(index + 1)...] {
                    let f = sibling.convert(sibling.bounds, to: nil)
                    let ptr = Unmanaged.passUnretained(sibling).toOpaque()
                    let owner = (sibling.next as? UIViewController).map { String(describing: type(of: $0)) } ?? "-"
                    out.append(
                        "\(type(of: sibling))@\(ptr)"
                        + "[\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]"
                        + " hidden=\(sibling.isHidden) alpha=\(sibling.alpha)"
                        + " opaque=\(sibling.isOpaque) bg=\(sibling.backgroundColor.map { "\($0)" } ?? "nil")"
                        + " owner=\(owner)"
                        + " under=\(String(describing: type(of: parent)))")
                }
            }
            node = parent
        }
        return out.isEmpty ? "none" : out.joined(separator: "  |  ")
    }

    static func chain(_ view: UIView?) -> String {
        var names: [String] = []
        var current = view
        while let node = current {
            var name = String(describing: type(of: node))
            if let owner = node.next as? UIViewController {
                name += "(\(String(describing: type(of: owner))))"
            }
            names.append(name)
            current = node.superview
        }
        return names.isEmpty ? "nil" : names.joined(separator: " < ")
    }
}

// MARK: - Query plumbing

extension SearchContainerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        results.updateSearchQuery(searchController.searchBar.text ?? "")
    }
}

extension SearchContainerViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        results.submitSearch()
    }
}
