// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit
import XCTest
@testable import Rivulet

/// The search bar has to clear the collapsed sidebar pill (#292).
///
/// This needs a mounted window rather than a pure calculation: the search
/// controller presents full screen into the window instead of laying out inside
/// our container, so the only thing that moves the bar is its safe area, and the
/// only way to know where the bar ended up is to ask it. A frame-based fix
/// looked correct and moved nothing.
final class SearchChromeLayoutTests: XCTestCase {

    @MainActor
    private func mountedSearchBar() -> (bar: UISearchBar, window: UIWindow)? {
        let sut = SearchContainerViewController()
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()

        host.addChild(sut)
        sut.view.frame = host.view.bounds
        host.view.addSubview(sut.view)
        sut.didMove(toParent: host)
        sut.beginAppearanceTransition(true, animated: false)
        sut.endAppearanceTransition()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        window.layoutIfNeeded()

        func find(_ view: UIView) -> UISearchBar? {
            if let bar = view as? UISearchBar { return bar }
            for sub in view.subviews { if let bar = find(sub) { return bar } }
            return nil
        }
        guard let bar = find(window) else { return nil }
        return (bar, window)
    }

    @MainActor
    func test_searchBar_startsBelowTheSidebarPill() throws {
        let mounted = try XCTUnwrap(mountedSearchBar(), "no search bar was mounted")
        let frame = try XCTUnwrap(mounted.bar.superview).convert(
            mounted.bar.frame, to: mounted.window)

        XCTAssertGreaterThanOrEqual(
            frame.minY, ShellPillMetrics.contentClearance,
            "search bar at \(NSCoder.string(for: frame)) runs under the pill")
    }

    /// The inset applied in `viewDidLoad` is a delta from this. If tvOS ever
    /// moves the bar's resting position, the delta is wrong even though the
    /// test above may still pass, so pin the number the delta is built on.
    @MainActor
    func test_titleSafeTop_stillMatchesWhereTVOSPutsTheBar() throws {
        let mounted = try XCTUnwrap(mountedSearchBar(), "no search bar was mounted")
        let frame = try XCTUnwrap(mounted.bar.superview).convert(
            mounted.bar.frame, to: mounted.window)
        let applied = ShellPillMetrics.contentClearance - SearchContainerViewController.titleSafeTop

        XCTAssertEqual(
            frame.minY - applied, SearchContainerViewController.titleSafeTop, accuracy: 0.5,
            "bar rests at \(frame.minY - applied), not titleSafeTop")
    }
}
