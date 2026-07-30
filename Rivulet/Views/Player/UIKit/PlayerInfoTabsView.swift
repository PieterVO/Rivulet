// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInfoTabsView.swift
//  Rivulet
//
//  Tabbed content for the player's Now Playing Info popup: a Description tab
//  (`CardDescriptionView`, title + summary), an Info tab (static `CardInfoView`
//  metadata) and an Advanced tab (`CardStatsView` live "stats for nerds"
//  telemetry). Sibling of `InsightsPanelContainerView` for the trivia panel,
//  simpler (no crossfade sub-state).
//
//  Not every tab exists for every item: Description needs a summary, and
//  Advanced needs the aether route (a non-nil advanced provider closure). Info
//  is always present, so an item with neither renders just the Info sheet with
//  no tab bar, exactly as the popup did before. Description leads when present
//  — reading the description is what the Info button is reached for (#267). The
//  Advanced sheet is built lazily on the first tab-over and ticks only while it
//  is the visible tab.
//
//  Focus: the sheets expose one invisible focus target per two-up ROW
//  (`InfoFocusRowView`), so the tab bar ↔ content crossings are ordinary
//  focus-engine moves that work identically for swipes and edge clicks — no
//  press handling here. (The previous single-focusable-sheet design drove
//  both crossings from arrow presses, which a Siri Remote swipe never
//  produces, so it only worked from clicks.)
//
//  Menu: intentionally does NOT conform to `RailPanelMenuHandling`, so
//  `PlayerRailPanelView` dismisses the whole panel from either tab.
//

import UIKit
import os

/// TEMP diagnostic instrumentation for the intermittent "Info tab doesn't
/// switch" / "can't move Down into the tab's content" reports — no confirmed
/// repro yet (simulator can't reliably reproduce tvOS focus behavior), so
/// this traces the actual on-device sequence for the next session. Remove
/// once the real cause is confirmed from a captured log.
private let infoTabLog = Logger(subsystem: "com.rivulet.app", category: "PlayerInfoTab")

final class PlayerInfoTabsView: UIView {

    /// One selectable tab in the Info popup's pill bar. Rendered by the shared
    /// `PillTabBarView` (same bar as the Insights panel), which addresses tabs
    /// by index into `availableTabs`.
    enum Tab {
        case description
        case info
        case advanced

        var title: String {
            switch self {
            case .description: return "Description"
            case .info: return "Info"
            case .advanced: return "Advanced"
            }
        }
    }

    private enum Metrics {
        static let tabBarSpacing: CGFloat = 16
    }

    private let descriptionView: CardDescriptionView?
    private let infoView: CardInfoView
    private var statsView: CardStatsView?
    private let advancedProvider: (() -> AetherAdvancedStats?)?
    private let availableTabs: [Tab]
    private let tabBar: PillTabBarView?
    private var currentTab: Tab

    private var contentTopAnchor: NSLayoutYAxisAnchor!
    private var contentTopConstant: CGFloat = 0
    private var contentSideInset: CGFloat = 0

    /// Forwarded to whichever content sheet holds focus, so the hosting panel
    /// can brighten its ring while the sheet is focused (the sheet is one big
    /// scroll target with no internal highlight of its own).
    var onFocusChange: ((Bool) -> Void)? {
        didSet {
            descriptionView?.onFocusChange = onFocusChange
            infoView.onFocusChange = onFocusChange
            statsView?.onFocusChange = onFocusChange
        }
    }

    /// The tabs available for one item, in display order — pure so it is
    /// unit-testable. Info always exists; the other two are conditional.
    static func tabs(hasDescription: Bool, hasAdvanced: Bool) -> [Tab] {
        var tabs: [Tab] = []
        if hasDescription { tabs.append(.description) }
        tabs.append(.info)
        if hasAdvanced { tabs.append(.advanced) }
        return tabs
    }

    /// A lone tab names itself in no bar at all.
    static func showsTabBar(hasDescription: Bool, hasAdvanced: Bool) -> Bool {
        tabs(hasDescription: hasDescription, hasAdvanced: hasAdvanced).count > 1
    }

    init(
        metadata: PlexMetadata,
        modes: StreamingModeInfo,
        advancedProvider: (() -> AetherAdvancedStats?)?
    ) {
        let hasDescription = !CardDescriptionView.paragraphs(of: metadata.summary).isEmpty
        let tabs = Self.tabs(hasDescription: hasDescription, hasAdvanced: advancedProvider != nil)
        self.descriptionView = hasDescription ? CardDescriptionView(metadata: metadata) : nil
        self.infoView = CardInfoView(metadata: metadata, modes: modes)
        self.advancedProvider = advancedProvider
        self.currentTab = tabs[0]
        self.availableTabs = tabs
        self.tabBar = tabs.count > 1 ? PillTabBarView(titles: tabs.map(\.title), selectedIndex: 0) : nil
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        infoView.translatesAutoresizingMaskIntoConstraints = false
        infoView.isHidden = currentTab != .info
        addSubview(infoView)

        if let descriptionView {
            descriptionView.translatesAutoresizingMaskIntoConstraints = false
            descriptionView.isHidden = currentTab != .description
            addSubview(descriptionView)
        }

        if let tabBar {
            tabBar.translatesAutoresizingMaskIntoConstraints = false
            tabBar.onSelect = { [weak self] index in
                guard let self, self.availableTabs.indices.contains(index) else { return }
                self.handleTabSelected(self.availableTabs[index])
            }
            addSubview(tabBar)
            NSLayoutConstraint.activate([
                tabBar.topAnchor.constraint(equalTo: topAnchor),
                tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
                tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            contentTopAnchor = tabBar.bottomAnchor
            contentTopConstant = Metrics.tabBarSpacing
            // Match the bar's own pill inset so a sheet's leading text edge
            // lines up with the pill capsules above it, the same relationship
            // the Insights panel gets from its matching `rowInset`. Without a
            // bar there is nothing to align to, so the sheet stays flush.
            contentSideInset = PillTabBarView.contentInset
        } else {
            contentTopAnchor = topAnchor
            contentTopConstant = 0
            contentSideInset = 0
        }

        constrainToContentArea(infoView)
        if let descriptionView { constrainToContentArea(descriptionView) }
    }

    /// Pins a content sheet to the area below the tab bar (or the whole view
    /// when there is no tab bar).
    private func constrainToContentArea(_ view: UIView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentTopAnchor, constant: contentTopConstant),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentSideInset),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentSideInset),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Tab switching

    private func handleTabSelected(_ tab: Tab) {
        infoTabLog.notice("tab select requested: \(String(describing: tab)) (current: \(String(describing: self.currentTab)))")
        guard tab != currentTab else {
            infoTabLog.notice("tab select no-op: already on \(String(describing: tab))")
            return
        }
        currentTab = tab
        if tab == .advanced { _ = ensureStatsView() }
        descriptionView?.isHidden = tab != .description
        infoView.isHidden = tab != .info
        statsView?.isHidden = tab != .advanced
        statsView?.setActive(tab == .advanced)
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
        addSubview(stats)
        constrainToContentArea(stats)
        statsView = stats
        return stats
    }

    // MARK: - Focus

    private var currentContentView: InfoTabSheet {
        switch currentTab {
        case .description: return descriptionView ?? infoView
        case .info: return infoView
        case .advanced: return statsView ?? infoView
        }
    }

    /// Set for the duration of one driven focus update — see `moveFocus(to:)`.
    private var focusEscapeTarget: UIView?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let focusEscapeTarget { return [focusEscapeTarget] }
        // Otherwise prefer the EXACT view that already holds focus, so a
        // re-resolution (e.g. a directional press that finds no spatial target
        // at the content's bottom edge) is a strict no-op instead of bouncing
        // focus to the tab bar or to a different row. Only the INITIAL landing
        // (focus not yet inside the content) falls through to the tab bar.
        if let focused = focusedViewInContent {
            infoTabLog.debug("preferredFocusEnvironments: re-affirming focused view in content")
            return [focused]
        }
        if let tabBar {
            infoTabLog.debug("preferredFocusEnvironments: landing on tab bar")
            return [tabBar]
        }
        infoTabLog.debug("preferredFocusEnvironments: landing on content (no tab bar)")
        return [currentContentView]
    }

    /// Points `preferredFocusEnvironments` at `target` for exactly one update.
    /// `setNeedsFocusUpdate` is ignored unless the requesting environment
    /// CONTAINS focus, so the request has to come from here — the common
    /// ancestor of the pills and the sheet rows — and not from either side.
    /// Same mechanism as `InsightsPanelContainerView.moveFocus(to:)`.
    private func moveFocus(to target: UIView) {
        focusEscapeTarget = target
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        focusEscapeTarget = nil
    }

    /// Drives the two crossings between the pills and the visible sheet.
    ///
    /// Neither happens natively: the pills and the sheet rows live in separate
    /// self-driven scroll views, and the focus engine's directional search does
    /// not reliably cross that boundary — Down from a pill did nothing at all
    /// on device. `InsightsPanelContainerView` reached the same conclusion for
    /// the trivia panel and drives both crossings the same way.
    ///
    /// Presses are delivered to the FOCUSED view and bubble up, so this runs
    /// for a press on a pill or on a row. Ordering matters for Up: the sheet's
    /// own `InfoScrollView.pressesBegan` sits below this in the chain and gets
    /// first refusal, so a press that still had somewhere to scroll never
    /// reaches here.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let tabBar {
            for press in presses {
                if press.type == .downArrow, tabBar.containsFocus {
                    infoTabLog.notice("driving focus: pills → content")
                    moveFocus(to: currentContentView)
                    return
                }
                if press.type == .upArrow, currentContentView.canEscapeUpward {
                    infoTabLog.notice("driving focus: content → pills")
                    moveFocus(to: tabBar)
                    return
                }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    /// The currently focused view, if it sits inside the visible content
    /// sheet (as opposed to the tab bar, or nowhere yet on first appearance).
    private var focusedViewInContent: UIView? {
        guard let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView else { return nil }
        guard focused === currentContentView || focused.isDescendant(of: currentContentView) else { return nil }
        return focused
    }
}
