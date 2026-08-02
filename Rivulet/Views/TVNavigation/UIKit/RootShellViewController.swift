// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  RootShellViewController.swift
//  Rivulet
//
//  The navigation shell: replaces the SwiftUI TabView(.sidebarAdaptable).
//  Owns one content child per tab (hosted SwiftUI, built by TVSidebarView's
//  tabContent so every existing behavior keeps its home), the custom sidebar
//  as chrome, the left-edge focus catcher, and the Menu policy. SwiftUI
//  remains the tab AUTHORITY: the shell reports intent through onTabChange,
//  and the selection binding pushes the result back via applySelection.
//

import UIKit
import os

/// Invisible focus target at the left edge; focus landing here means the
/// user pushed left out of content, which opens the sidebar.
private final class EdgeCatcherView: UIView {
    override var canBecomeFocused: Bool { true }
}

final class RootShellViewController: UIViewController {

    /// Builds a content controller for a tab. Set before the view loads.
    var makeContent: ((SidebarTab) -> UIViewController)?
    /// Reports tab intent upward to the SwiftUI selection binding.
    var onTabChange: ((SidebarTab) -> Void)?

    /// Nested detail / Settings sub-page: sidebar cannot open, pill hides,
    /// and Menu is left alone for the surface's own back handling.
    var interactionBlocked = false {
        didSet { updateChromeVisibility() }
    }
    /// Music library selected: music draws its own sidebar, ours stays out.
    var pillSuppressed = false {
        didSet { updateChromeVisibility() }
    }

    private(set) var currentTab: SidebarTab = .home
    private var contentVCs: [SidebarTab: UIViewController] = [:]
    private let sidebar = ShellSidebarViewController()
    private let edgeCatcher = EdgeCatcherView()
    private var belowTop = false
    /// The edge catcher stays out of the focus system until the CURRENTLY
    /// MOUNTED content has genuinely held focus; otherwise a focus search run
    /// while content is not yet focusable lands on it.
    ///
    /// Scoped per mount, not per launch (issue #280). A freshly mounted tab is
    /// exactly as unfocusable as content is at launch — the hosted SwiftUI
    /// takes a few runloop turns to build its focus items — so the launch
    /// guard has to re-arm on every switch. It did not, and Search and
    /// Discover were dead on arrival: focus parked on the invisible 2pt strip
    /// and, because nothing re-resolves once it settles, no direction did
    /// anything at all until the user left the tab.
    private var contentHasHadFocus = false
    private var pendingSections: [ShellSidebarSection]?
    /// Bounded retry that pushes focus into freshly mounted content — see
    /// `driveFocusIntoContent()`.
    private var contentFocusRetries = 0
    /// Set when the retry budget ran out and content never took focus, which
    /// means the surface has NOTHING focusable (a state view with no action
    /// button, say). The catcher is re-armed then purely as an escape hatch:
    /// with focus nowhere, `handleMenuBack` declines and Menu quits the app,
    /// so the user needs something to press Left/Menu against.
    private var contentFocusGaveUp = false

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        mountContent(for: currentTab)

        sidebar.embedded = true
        addChild(sidebar)
        sidebar.view.frame = view.bounds
        sidebar.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sidebar.view)
        sidebar.didMove(toParent: self)
        sidebar.setExpanded(false, animated: false)
        if let pendingSections { sidebar.setSections(pendingSections) }

        sidebar.onTabSelected = { [weak self] tab in
            self?.onTabChange?(tab)
            self?.collapseSidebar()
        }
        sidebar.onCollapseRequested = { [weak self] in self?.collapseSidebar() }

        // Full-height strip at the leading edge: a Left press from any content
        // (hero Play, a shelf's first tile) lands here and opens the sidebar.
        edgeCatcher.frame = CGRect(x: 0, y: 0, width: 2, height: view.bounds.height)
        edgeCatcher.autoresizingMask = [.flexibleHeight]
        edgeCatcher.isHidden = true
        view.addSubview(edgeCatcher)

        MenuPressInterceptor.register(self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBelowTopChanged(_:)),
            name: .contentFocusBelowTopChanged, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let window = view.window { MenuPressInterceptor.install(in: window) }
    }

    // MARK: Selection (SwiftUI is the authority)

    /// Called from the representable whenever the binding changes (or any
    /// SwiftUI update runs); idempotent.
    func applySelection(_ tab: SidebarTab) {
        guard isViewLoaded else { currentTab = tab; return }
        sidebar.setSelectedTabExternal(tab)
        guard tab != currentTab else { return }
        currentTab = tab
        // `mountContent` owns the focus hand-off into the new tab (it is the
        // only place that knows the content is fresh and not yet focusable).
        mountContent(for: tab)
    }

    /// Live sidebar content, pushed from SwiftUI on every relevant change.
    func updateSections(_ sections: [ShellSidebarSection]) {
        guard isViewLoaded else { pendingSections = sections; return }
        sidebar.setSections(sections)
    }

    /// Re-points every cached hosting controller at a freshly built root so
    /// content stays reactive to TVSidebarView's observed state. The adopt
    /// call lives on RootShellHostingController (SwiftUI side) so this file
    /// stays SwiftUI-free.
    func refreshContentRoots(_ build: (SidebarTab) -> UIViewController?) {
        for tab in contentVCs.keys {
            guard let fresh = build(tab),
                  let host = contentVCs[tab] as? RootShellHostingController else { continue }
            host.adoptRoot(from: fresh)
        }
    }

    private func mountContent(for tab: SidebarTab) {
        guard let makeContent else { return }
        for (_, vc) in contentVCs where vc.view.superview != nil {
            vc.beginAppearanceTransition(false, animated: false)
            vc.view.removeFromSuperview()
            vc.endAppearanceTransition()
        }
        let next: UIViewController
        if let cached = contentVCs[tab] {
            next = cached
        } else {
            next = makeContent(tab)
            contentVCs[tab] = next
            addChild(next)
            next.didMove(toParent: self)
        }
        next.beginAppearanceTransition(true, animated: false)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(next.view, at: 0)
        next.endAppearanceTransition()

        // This content has not held focus yet, so the edge catcher goes back
        // out of the focus system until it has (see `contentHasHadFocus`), and
        // focus has to be pushed in once the hosted SwiftUI is focusable.
        contentHasHadFocus = false
        contentFocusGaveUp = false
        updateChromeVisibility()
        driveFocusIntoContent()
    }

    /// Ask the engine to resolve focus into the mounted content, retrying until
    /// it actually lands.
    ///
    /// One synchronous request is not enough. The tab's SwiftUI content is not
    /// focusable in the same runloop turn it is mounted in, so a single
    /// `updateFocusIfNeeded()` finds nothing and focus stays wherever it is —
    /// and once focus settles nothing asks again. Retry on the runloop until
    /// content takes it (`contentHasHadFocus`, set from `didUpdateFocus`) or
    /// the budget runs out, so an unfocusable surface degrades to "focus
    /// nowhere" rather than to a hang.
    private func driveFocusIntoContent() {
        contentFocusRetries = 20        // ~1s at 50ms
        retryFocusIntoContent()
    }

    private func retryFocusIntoContent() {
        guard !contentHasHadFocus, !sidebar.isExpanded else { return }
        guard contentFocusRetries > 0 else {
            contentFocusGaveUp = true
            updateChromeVisibility()
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            return
        }
        contentFocusRetries -= 1
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        guard !contentHasHadFocus else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.retryFocusIntoContent()
        }
    }

    // MARK: Sidebar chrome

    private func expandSidebar() {
        guard !sidebar.isExpanded, !interactionBlocked else { return }
        sidebar.setExpanded(true, animated: true)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func collapseSidebar() {
        guard sidebar.isExpanded else { return }
        sidebar.setExpanded(false, animated: true)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func updateChromeVisibility() {
        guard isViewLoaded else { return }
        if interactionBlocked, sidebar.isExpanded { collapseSidebar() }
        sidebar.setPillHidden(belowTop || pillSuppressed || interactionBlocked)
        // While expanded, the sidebar's focus containment already guards the
        // catcher; it only needs to vanish when interaction is blocked or
        // before the mounted content has held focus (see `contentHasHadFocus`
        // and `contentFocusGaveUp`).
        edgeCatcher.isHidden = interactionBlocked || !(contentHasHadFocus || contentFocusGaveUp)
    }

    @objc private func handleBelowTopChanged(_ note: Notification) {
        belowTop = note.object as? Bool ?? false
        updateChromeVisibility()
    }

    // MARK: Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if sidebar.isExpanded { return [sidebar.focusTarget] }
        if let content = contentVCs[currentTab] { return [content] }
        return super.preferredFocusEnvironments
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let next = context.nextFocusedView else { return }
        if next === edgeCatcher {
            let cameFromContent = context.previouslyFocusedView.map {
                $0.isDescendant(of: view) && !$0.isDescendant(of: sidebar.view)
            } ?? false
            if cameFromContent {
                expandSidebar()
            } else {
                // Spurious landing (launch search); bounce back to content.
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
            return
        }
        if !contentHasHadFocus, next.isDescendant(of: view), !next.isDescendant(of: sidebar.view) {
            contentHasHadFocus = true
            updateChromeVisibility()
        }
    }
}

// MARK: - Menu policy

extension RootShellViewController: MenuBackHandling {
    /// Offered AFTER content handlers (registration order): by the time this
    /// runs, the home page has already consumed below-top Menu presses.
    func handleMenuBack() -> Bool {
        guard view.window?.isKeyWindow == true else { return false }
        // Focus must be inside the shell's OWN hierarchy. `isKeyWindow` stays
        // true while a modal covers the shell — the preview carousel's expanded
        // detail, the player — because a modal is presented into the SAME
        // window. Without this the shell claimed Menu on behalf of a sidebar
        // the user cannot see, expanded it invisibly, and returned true. The
        // press was then withheld from the system AND never reached the modal's
        // own Menu recognizer, so Menu in the carousel's below-fold did nothing
        // at all. Worse, the invisible expand flipped `sidebar.isExpanded`, so
        // the NEXT press took the collapse branch, returned false, and worked:
        // every other Menu press died.
        //
        // A presented controller's view is added to the window, never to the
        // presenter's view, so descendancy is an exact test. `sidebar.view` IS
        // a subview here, so the expanded-sidebar branch still qualifies. This
        // is the same containment check `PlexHomeViewController.handleMenuBack`
        // already makes, which is why home correctly declined and only the
        // shell absorbed the press.
        guard let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView,
              focused.isDescendant(of: view)
        else { return false }
        if sidebar.isExpanded {
            // Menu in the open sidebar returns to Home (issue #192 policy);
            // on Home it falls through so the system can exit the app.
            guard currentTab != .home else {
                collapseSidebar()
                return false
            }
            onTabChange?(.home)
            collapseSidebar()
            return true
        }
        guard !interactionBlocked else { return false }
        expandSidebar()
        return true
    }
}
