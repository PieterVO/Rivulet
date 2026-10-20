// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexLibraryModeViewController.swift
//  Rivulet
//
//  A Plex movie or show library tab: its title grid or its folders, swapped in
//  place. The choice is saved per library and profile.
//

import UIKit

@MainActor
final class PlexLibraryModeViewController: UIViewController {
    private let library: PlexLibrary
    private var grid: PlexHomeViewController?
    private var folders: FolderLibraryViewController?
    private var active: UIViewController?

    init(library: PlexLibrary) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let mode = LibrarySettingsManager.shared.viewMode(library.key)
        if mode != .folders { gridPage().setGridShowsCollections(mode == .collections) }
        show(byFolder: mode == .folders)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { active.map { [$0] } ?? [] }

    /// Both pages are kept once made, so switching back keeps place and contents.
    private func page(byFolder: Bool) -> UIViewController {
        guard byFolder else { return gridPage() }
        if let folders { return folders }
        let page = FolderLibraryViewController(plex: library) { [weak self] in
            guard let self else { return nil }
            // Collections only once the grid has seen some.
            let modes: [LibraryViewMode] = grid?.hasCollections == true
                ? [.titles, .collections, .folders] : [.titles, .folders]
            return LibraryViewMode.menu(modes, current: .folders) { [weak self] in self?.select($0) }
        }
        folders = page
        return page
    }

    private func gridPage() -> PlexHomeViewController {
        if let grid { return grid }
        let page = PlexHomeViewController(mode: .library(key: library.key, title: library.title))
        page.onSelectViewMode = { [weak self] in self?.select($0) }
        grid = page
        return page
    }

    private func select(_ mode: LibraryViewMode) {
        LibrarySettingsManager.shared.setViewMode(mode, for: library.key)
        // Next turn: the menu's button is in the page being removed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if mode != .folders { gridPage().setGridShowsCollections(mode == .collections) }
            guard (mode == .folders) != (active === folders) else { return }
            show(byFolder: mode == .folders)
            NotificationCenter.default.post(name: .tabContentReplaced, object: self)
        }
    }

    private func show(byFolder: Bool) {
        let next = page(byFolder: byFolder)
        guard next !== active else { return }
        let previous = active
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(next.view)
        next.didMove(toParent: self)
        active = next
        // Focus is still in the old page, so this request is ours to make.
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        previous?.willMove(toParent: nil)
        previous?.view.removeFromSuperview()
        previous?.removeFromParent()
    }
}
