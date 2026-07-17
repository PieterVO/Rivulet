// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInfoTabsView.swift
//  Rivulet
//
//  Tabbed content for the player's Now Playing Info popup: an Info tab (static
//  `CardInfoView` metadata) and an Advanced tab (`CardStatsView` live "stats
//  for nerds" telemetry). Sibling of `InsightsPanelContainerView` for the
//  trivia panel, simpler (no crossfade sub-state).
//
//  The Advanced tab exists only on the aether route (a non-nil advanced
//  provider closure); on the hls route this renders just the Info sheet with
//  no tab bar, exactly as the popup did before. The Advanced sheet is built
//  lazily on the first tab-over and ticks only while it is the visible tab.
//
//  Menu: intentionally does NOT conform to `RailPanelMenuHandling`, so
//  `PlayerRailPanelView` dismisses the whole panel from either tab.
//

import UIKit

final class PlayerInfoTabsView: UIView {

    private enum Metrics {
        static let tabBarSpacing: CGFloat = 16
    }

    private let infoView: CardInfoView
    private var statsView: CardStatsView?
    private let advancedProvider: (() -> AetherAdvancedStats?)?
    private let tabBar: InfoTabBarView?
    private var currentTab: InfoTabBarView.Tab = .info

    /// Transient directional-escape target (see `InsightsPanelContainerView`):
    /// the focus engine ignores a `setNeedsFocusUpdate()` from an environment
    /// that does not CONTAIN focus, so the cross-boundary move must be
    /// requested from this container (the common ancestor of the tab bar and
    /// the content), with `preferredFocusEnvironments` pointing at the target
    /// for the duration of that one update.
    private var focusEscapeTarget: UIView?

    private var contentTopAnchor: NSLayoutYAxisAnchor!
    private var contentTopConstant: CGFloat = 0

    /// Forwarded to whichever content sheet holds focus, so the hosting panel
    /// can brighten its ring while the sheet is focused (the sheet is one big
    /// scroll target with no internal highlight of its own).
    var onFocusChange: ((Bool) -> Void)? {
        didSet {
            infoView.onFocusChange = onFocusChange
            statsView?.onFocusChange = onFocusChange
        }
    }

    /// Whether to show the tab bar at all — pure so it is unit-testable. The
    /// Advanced tab (and thus the tab bar) exists iff there is an advanced
    /// provider, i.e. the aether route.
    static func showsTabBar(advancedProvider: (() -> AetherAdvancedStats?)?) -> Bool {
        advancedProvider != nil
    }

    init(
        metadata: PlexMetadata,
        modes: StreamingModeInfo,
        advancedProvider: (() -> AetherAdvancedStats?)?
    ) {
        self.infoView = CardInfoView(metadata: metadata, modes: modes)
        self.advancedProvider = advancedProvider
        self.tabBar = Self.showsTabBar(advancedProvider: advancedProvider) ? InfoTabBarView(selected: .info) : nil
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        infoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(infoView)

        if let tabBar {
            tabBar.translatesAutoresizingMaskIntoConstraints = false
            tabBar.onSelect = { [weak self] tab in self?.handleTabSelected(tab) }
            addSubview(tabBar)
            NSLayoutConstraint.activate([
                tabBar.topAnchor.constraint(equalTo: topAnchor),
                tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
                tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            contentTopAnchor = tabBar.bottomAnchor
            contentTopConstant = Metrics.tabBarSpacing
            // Only wire the Up-escape when there is a tab bar to escape to.
            infoView.onEscapeUp = { [weak self] in self?.escapeToTabBar() }
        } else {
            contentTopAnchor = topAnchor
            contentTopConstant = 0
        }

        constrainToContentArea(infoView)
    }

    /// Pins a content sheet to the area below the tab bar (or the whole view
    /// when there is no tab bar).
    private func constrainToContentArea(_ view: UIView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentTopAnchor, constant: contentTopConstant),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Tab switching

    private func handleTabSelected(_ tab: InfoTabBarView.Tab) {
        guard tab != currentTab else { return }
        currentTab = tab
        switch tab {
        case .info:
            statsView?.setActive(false)
            statsView?.isHidden = true
            infoView.isHidden = false
        case .advanced:
            let stats = ensureStatsView()
            infoView.isHidden = true
            stats.isHidden = false
            stats.setActive(true)
        }
    }

    /// Builds the Advanced sheet on first use. Only reachable when a tab bar
    /// exists, which requires a non-nil `advancedProvider`.
    private func ensureStatsView() -> CardStatsView {
        if let statsView { return statsView }
        let provider = advancedProvider ?? { nil }
        let stats = CardStatsView(provider: provider)
        stats.translatesAutoresizingMaskIntoConstraints = false
        stats.isHidden = true
        stats.onFocusChange = onFocusChange
        stats.onEscapeUp = { [weak self] in self?.escapeToTabBar() }
        addSubview(stats)
        constrainToContentArea(stats)
        statsView = stats
        return stats
    }

    // MARK: - Focus

    private var currentContentView: UIView {
        switch currentTab {
        case .info: return infoView
        case .advanced: return statsView ?? infoView
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let focusEscapeTarget { return [focusEscapeTarget] }
        // Land on the tab bar so focus starts on the pills — the content is a
        // single scroll surface that traps swipes (a swipe is never an arrow
        // UIPress), so a swipe-user who started IN the content could never get
        // up to the tabs. Directional Down still moves into the content, and a
        // click-Up at the content's top escapes back here.
        if let tabBar { return [tabBar] }
        return [currentContentView]
    }

    private func moveFocus(to target: UIView) {
        focusEscapeTarget = target
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        focusEscapeTarget = nil
    }

    private func escapeToTabBar() {
        guard let tabBar else { return }
        moveFocus(to: tabBar)
    }

    /// Down from a pill → the current content. (Up from the content's top edge
    /// is driven the other way, by the content's `onEscapeUp`.) The focus
    /// engine's own directional search does not reliably cross the tab-bar ↔
    /// scroll-view boundary, so both crossings are driven explicitly.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let tabBar {
            for press in presses where press.type == .downArrow {
                if tabBar.containsFocus {
                    moveFocus(to: currentContentView)
                    return
                }
            }
        }
        super.pressesBegan(presses, with: event)
    }
}
