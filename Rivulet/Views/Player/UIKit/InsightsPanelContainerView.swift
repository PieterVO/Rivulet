// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsPanelContainerView.swift
//  Rivulet
//
//  Two-state content for the Insights rail panel (Docs/superpowers/specs/
//  2026-07-08-insights-toptrivia-tabs-design.md). Replaces the old
//  person-page deep link: selecting a cast member CROSSFADES IN PLACE from
//  the cast list to an actor view (portrait + bio + filmography) while video
//  keeps playing — no pause/resume, no VC presentation anywhere in this flow.
//  Above the list/actor content sits a pill tab bar (Top 10 | Cast |
//  category pills) that switches which tab-scoped row set the list shows.
//
//  Menu handling: `PlayerRailPanelView.pressesBegan` owns Menu for the whole
//  panel and gives this content first refusal via `RailPanelMenuHandling` —
//  in `.actor` state `handleMenuPress()` reverse-crossfades back to `.list`
//  and the panel stays open; in `.list` state it declines and the panel
//  dismisses.
//

import UIKit

final class InsightsPanelContainerView: UIView, RailPanelMenuHandling {

    private enum Metrics {
        /// Height cap for the `.actor` state — matches PlayerRailPanelView's
        /// own `maxHeight` (560) minus its content padding (20 top + 20
        /// bottom), so the panel never exceeds its own ceiling.
        static let actorHeightCap: CGFloat = 520
        static let crossfadeDuration: TimeInterval = 0.2
        static let tabBarSpacing: CGFloat = 16
    }

    private enum State {
        case list
        case actor
    }

    private let cast: [MediaPerson]
    private let trivia: TitleTrivia?
    private let suppressedTriviaIDs: Set<String>
    private let hideSpoilers: Bool
    private let provider: PersonFilmographyProviding

    private let availableTabs: [InsightsTab]
    private var currentTab: InsightsTab

    private lazy var tabBar: InsightsTabBarView? = {
        guard !availableTabs.isEmpty else { return nil }
        let bar = InsightsTabBarView(tabs: availableTabs, selected: currentTab)
        bar.onSelect = { [weak self] tab in self?.handleTabSelected(tab) }
        return bar
    }()

    // `lazy` so the init closure can capture `self` directly — evaluated on
    // first access (from `init`, after `super.init()` has returned), so
    // `self` is fully formed by the time `InsightsCastListView`'s own init
    // runs. Simpler than routing through an intermediate box.
    private lazy var listView = InsightsCastListView(
        cast: cast,
        trivia: trivia,
        suppressedTriviaIDs: suppressedTriviaIDs,
        hideSpoilers: hideSpoilers,
        initialTab: currentTab,
        onSelectCast: { [weak self] person in
            self?.crossfadeToActor(person)
        })
    /// Internal (not private) visibility so `@testable import Rivulet` tests
    /// can observe the currently-hosted actor view (e.g. to confirm a stale
    /// load never reached it after the user backed out / switched actors).
    private(set) var actorView: InsightsActorView?
    private let coordinator = InsightsActorLoadCoordinator()
    private var state: State = .list

    private var heightConstraint: NSLayoutConstraint!

    init(
        cast: [MediaPerson],
        trivia: TitleTrivia? = nil,
        suppressedTriviaIDs: Set<String> = [],
        hideSpoilers: Bool = true,
        provider: PersonFilmographyProviding = PersonFilmographyProvider()
    ) {
        self.cast = cast
        self.trivia = trivia
        self.suppressedTriviaIDs = suppressedTriviaIDs
        self.hideSpoilers = hideSpoilers
        self.provider = provider
        let tabs = InsightsTabBarView.availableTabs(
            cast: cast, trivia: trivia, suppressedTriviaIDs: suppressedTriviaIDs, hideSpoilers: hideSpoilers)
        self.availableTabs = tabs
        // Prefer Top 10 as the landing tab when available (it's the curated
        // highlight reel); otherwise Cast; otherwise the first category.
        self.currentTab = tabs.first(where: { $0 == .topTen }) ?? tabs.first ?? .cast
        super.init(frame: .zero)

        listView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listView)

        if let tabBar {
            tabBar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tabBar)
            NSLayoutConstraint.activate([
                tabBar.topAnchor.constraint(equalTo: topAnchor),
                tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
                tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),

                listView.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: Metrics.tabBarSpacing),
                listView.leadingAnchor.constraint(equalTo: leadingAnchor),
                listView.trailingAnchor.constraint(equalTo: trailingAnchor),
                listView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                listView.topAnchor.constraint(equalTo: topAnchor),
                listView.leadingAnchor.constraint(equalTo: leadingAnchor),
                listView.trailingAnchor.constraint(equalTo: trailingAnchor),
                listView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Tab switching

    private func handleTabSelected(_ tab: InsightsTab) {
        guard tab != currentTab, state == .list else { return }
        currentTab = tab
        listView.setTab(tab)
    }

    // MARK: - Crossfade

    /// Internal (not private) visibility so `@testable import Rivulet`
    /// integration tests can drive selection directly (in production this
    /// only ever fires from `InsightsCastListView`'s row `onSelect`).
    func crossfadeToActor(_ person: MediaPerson) {
        guard state == .list else { return }
        let token = coordinator.begin()

        let actor = InsightsActorView(person: person)
        actor.translatesAutoresizingMaskIntoConstraints = false
        actor.alpha = 0
        addSubview(actor)
        NSLayoutConstraint.activate([
            actor.topAnchor.constraint(equalTo: topAnchor),
            actor.leadingAnchor.constraint(equalTo: leadingAnchor),
            actor.trailingAnchor.constraint(equalTo: trailingAnchor),
            actor.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        actorView = actor
        state = .actor

        // The outgoing list/tab bar are only alpha-faded, not removed (the
        // reverse crossfade needs them intact to fade back in) — without
        // this, they stay focusable and hit-testable while invisible, so a
        // directional focus search from inside the actor view could land on
        // a hidden row: the user would see the actor view but actually be
        // focused underneath it. Matches this codebase's fullScreenCover-
        // style focus isolation principle for any overlay state.
        listView.isUserInteractionEnabled = false
        tabBar?.isUserInteractionEnabled = false

        heightConstraint.constant = Metrics.actorHeightCap
        heightConstraint.isActive = true
        setNeedsFocusUpdate()
        updateFocusIfNeeded()

        UIView.animate(withDuration: Metrics.crossfadeDuration, animations: {
            self.listView.alpha = 0
            self.tabBar?.alpha = 0
            actor.alpha = 1
            self.superview?.layoutIfNeeded()
        }, completion: { [weak self] _ in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        })

        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.provider.load(person: person)
            guard self.coordinator.isCurrent(token) else { return }
            // The actor view for THIS token is still `self.actorView` as
            // long as no newer selection/cancel has happened (guaranteed by
            // the token check above — cancel()/begin() are the only ways
            // the token goes stale, and both accompany a state change that
            // replaces or tears down `actorView`).
            if let result {
                actor.populate(result)
            } else {
                actor.showDetailsUnavailable()
            }
        }
    }

    /// Internal (not private) visibility — see `crossfadeToActor`.
    func reverseCrossfadeToList() {
        guard state == .actor, let actor = actorView else { return }
        coordinator.cancel()
        state = .list
        listView.isUserInteractionEnabled = true
        tabBar?.isUserInteractionEnabled = true

        heightConstraint.isActive = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()

        UIView.animate(withDuration: Metrics.crossfadeDuration, animations: {
            actor.alpha = 0
            self.listView.alpha = 1
            self.tabBar?.alpha = 1
            self.superview?.layoutIfNeeded()
        }, completion: { [weak self] _ in
            actor.removeFromSuperview()
            if self?.actorView === actor {
                self?.actorView = nil
            }
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        })
    }

    // MARK: - Focus

    /// Transient directional-escape target. The tvOS focus engine ignores a
    /// `setNeedsFocusUpdate()` from an environment that does not CONTAIN the
    /// currently-focused item, so the tab bar can never pull focus to itself
    /// — the request must come from this container (the common ancestor of
    /// the focused row and the tab bar), with `preferredFocusEnvironments`
    /// pointing at the escape target for the duration of that one update.
    private var focusEscapeTarget: UIView?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let focusEscapeTarget { return [focusEscapeTarget] }
        switch state {
        case .list: return [listView]
        case .actor: return actorView.map { [$0] } ?? [listView]
        }
    }

    private func moveFocus(to target: UIView) {
        focusEscapeTarget = target
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        focusEscapeTarget = nil
    }

    /// Directional escapes across the list/tab-bar boundary. Presses are
    /// delivered to the focused view and bubble UP the responder chain, so
    /// this override runs for any press while focus is on a row or pill
    /// (both are descendants). The focus engine's own directional search
    /// does not reliably cross the scroll-view boundaries between the two,
    /// so both crossings are driven explicitly:
    /// - Up on the list's first row → the tab bar (its own
    ///   `preferredFocusEnvironments` picks the selected pill).
    /// - Down from a pill → the list (lands per the list's own preference).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if state == .list, let tabBar {
            for press in presses {
                if press.type == .upArrow, listView.isFocusOnFirstRow() {
                    moveFocus(to: tabBar)
                    return
                }
                if press.type == .downArrow, tabBar.containsFocus {
                    moveFocus(to: listView)
                    return
                }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: - Menu handling

    /// Content-first-refusal on Menu, called from
    /// `PlayerRailPanelView.pressesBegan` (see `RailPanelMenuHandling`).
    /// Not a `pressesBegan` override here: in `.actor` state nothing inside
    /// this view may be focusable (bio header, filmography still loading),
    /// so focus falls to the panel view itself — and a press delivered to
    /// the panel bubbles UP from it, never down into its children.
    func handleMenuPress() -> Bool {
        guard state == .actor else { return false }
        reverseCrossfadeToList()
        return true
    }
}
