// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsTriviaRowLayoutTests.swift
//  RivuletTests
//
//  Repro harness for the "tab shows same-sized empty containers" report
//  (2026-07-08 manual round): trivia rows on some tabs rendered as uniform
//  empty boxes instead of text-driven-height rows. Asserts that rows built
//  through BOTH construction paths — init(initialTab:) and a later
//  setTab(_:) — resolve to heights driven by their actual text length once
//  laid out at the panel's real width.
//

import XCTest
@testable import Rivulet

@MainActor
final class InsightsTriviaRowLayoutTests: XCTestCase {

    private let longText = String(repeating: "A reasonably long trivia sentence that must wrap across several lines. ", count: 4)

    private func makeTrivia() -> TitleTrivia {
        let json = """
        { "id": "tmdb://1", "type": "movie", "generatedAt": "2026-07-07T00:00:00Z", "pipelineVersion": 2,
          "attribution": [{ "name": "Wikipedia", "url": "https://w/x" }],
          "facts": [
            { "id": "f1", "text": "\(longText)", "category": "production", "spoiler": 0,
              "source": { "name": "Wikipedia", "url": "https://w/x" } },
            { "id": "f2", "text": "Short fact.", "category": "production", "spoiler": 0,
              "source": { "name": "Wikipedia", "url": "https://w/x" } }
          ] }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(TitleTrivia.self, from: json)
    }

    /// Hosts the list at the Insights panel's real content width and forces
    /// a full layout pass, mirroring PlayerRailPanelView's sizing (width
    /// 640 minus 2x20 content padding).
    /// Retained so the hierarchy stays window-attached for the test's
    /// lifetime — matching device conditions, where the full
    /// update-constraints + layout pass runs via the CA transaction.
    private var window: UIWindow?

    private func layout(_ list: InsightsCastListView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 560))
        self.window = window
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        list.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: host.topAnchor),
            list.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        window.layoutIfNeeded()
    }

    private func triviaRows(in list: InsightsCastListView) -> [InsightsTriviaRowView] {
        func collect(_ view: UIView) -> [InsightsTriviaRowView] {
            view.subviews.flatMap { ($0 as? InsightsTriviaRowView).map { [$0] } ?? collect($0) }
        }
        return collect(list)
    }

    private func assertTextDrivenHeights(_ list: InsightsCastListView, path: String) {
        let rows = triviaRows(in: list)
        XCTAssertEqual(rows.count, 2, "\(path): expected both facts as rows")
        let heights = rows.map(\.bounds.height).sorted()
        XCTAssertGreaterThan(heights.last ?? 0, 100,
                             "\(path): long fact should wrap to a tall row, got \(heights)")
        XCTAssertGreaterThan((heights.last ?? 0) - (heights.first ?? 0), 30,
                             "\(path): long and short facts must differ in height (uniform heights = the ambiguous-layout fallback), got \(heights)")
    }

    /// Full-fidelity repro: the container inside a real PlayerRailPanelView
    /// presented above a rail in a window (exactly the production hierarchy),
    /// then a tab switch — the on-device report was "some tabs show
    /// same-sized empty containers" after navigating pills.
    func test_panelContext_tabSwitch_rowsHaveTextDrivenHeights() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        self.window = window
        let root = UIView(frame: window.bounds)
        window.addSubview(root)
        window.isHidden = false

        let rail = UIView()
        root.addSubview(rail)
        rail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 132),
            rail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -132),
            rail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -60),
            rail.heightAnchor.constraint(equalToConstant: 120),
        ])

        // Cast present so the initial tab is Cast-adjacent Top 10 absent —
        // mirror the real flow: land on a tab, then switch to a category.
        let container = InsightsPanelContainerView(
            cast: [], trivia: makeTrivia(), suppressedTriviaIDs: [], hideSpoilers: true)
        PlayerRailPanelView.present(content: container, width: 640, in: root, aboveRail: rail, towards: rail)
        window.layoutIfNeeded()

        let list = container.subviews.compactMap { $0 as? InsightsCastListView }.first
        XCTAssertNotNil(list)

        // Drive the tab switch the way a pill select does.
        list.map { $0.setTab(.category(.production)) }
        window.layoutIfNeeded()

        list.map { assertTextDrivenHeights($0, path: "panel+setTab") }
    }

    /// Ratatouille-shaped repro: a category with MANY long facts (52
    /// production facts on device), which is the difference between the
    /// tabs that rendered empty and Adaptation (3 short facts) which did
    /// not. Builds the panel, lands on the many-fact category, and asserts
    /// the rows actually resolved text-driven heights rather than the
    /// uniform ambiguous-layout fallback.
    func test_manyLongFacts_rowsHaveTextDrivenHeights() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        self.window = window
        let root = UIView(frame: window.bounds)
        window.addSubview(root)
        window.isHidden = false

        // 30 production facts of realistic length (60-160 chars).
        let facts = (0..<30).map { i -> String in
            let n = 60 + (i * 7) % 100
            return "Fact \(i): " + String(repeating: "word ", count: n / 5)
        }
        let factsJSON = facts.enumerated().map { i, t in
            """
            { "id": "p\(i)", "text": "\(t.trimmingCharacters(in: .whitespaces))", "category": "production", "spoiler": 0,
              "source": { "name": "Wikipedia", "url": "https://w/x" } }
            """
        }.joined(separator: ",")
        let json = """
        { "id": "tmdb://2062", "type": "movie", "generatedAt": "2026-07-07T00:00:00Z", "pipelineVersion": 2,
          "attribution": [{ "name": "Wikipedia", "url": "https://w/x" }], "facts": [\(factsJSON)] }
        """.data(using: .utf8)!
        let trivia = try! JSONDecoder().decode(TitleTrivia.self, from: json)

        let rail = UIView()
        root.addSubview(rail)
        rail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 132),
            rail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -132),
            rail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -60),
            rail.heightAnchor.constraint(equalToConstant: 120),
        ])

        let container = InsightsPanelContainerView(
            cast: [], trivia: trivia, suppressedTriviaIDs: [], hideSpoilers: true)
        PlayerRailPanelView.present(content: container, width: 640, in: root, aboveRail: rail, towards: rail)
        window.layoutIfNeeded()

        let list = container.subviews.compactMap { $0 as? InsightsCastListView }.first
        XCTAssertNotNil(list)
        list.map { $0.setTab(.category(.production)) }
        window.layoutIfNeeded()

        let rows = triviaRows(in: list!)
        XCTAssertEqual(rows.count, 30)
        let zeroHeight = rows.filter { $0.bounds.height < 1 }.count
        XCTAssertEqual(zeroHeight, 0, "\(zeroHeight)/30 rows collapsed to zero height (the empty-container bug)")
        let heights = Set(rows.map { Int($0.bounds.height.rounded()) })
        XCTAssertGreaterThan(heights.count, 1, "all rows identical height = ambiguous-layout fallback, not text-driven: \(heights)")
    }

    func test_initPath_rowsHaveTextDrivenHeights() {
        let list = InsightsCastListView(
            cast: [], trivia: makeTrivia(), suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .category(.production), onSelectCast: { _ in })
        layout(list)
        assertTextDrivenHeights(list, path: "init")
    }

    func test_setTabPath_rowsHaveTextDrivenHeights() {
        let list = InsightsCastListView(
            cast: [], trivia: makeTrivia(), suppressedTriviaIDs: [], hideSpoilers: true,
            initialTab: .topTen, onSelectCast: { _ in })
        layout(list)
        list.setTab(.category(.production))
        window?.layoutIfNeeded()
        let rows = triviaRows(in: list)
        func frames(_ v: UIView, depth: Int = 0) -> String {
            let pad = String(repeating: "  ", count: depth)
            return "\(pad)\(type(of: v)) frame=\(v.frame) ambiguous=\(v.hasAmbiguousLayout)\n"
                + v.subviews.map { frames($0, depth: depth + 1) }.joined()
        }
        XCTAssertFalse(rows.isEmpty, "no rows found")
        if rows.first?.bounds.height == 0 {
            XCTFail("diagnostics:\n\(frames(list))")
        }
        assertTextDrivenHeights(list, path: "setTab")
    }
}
