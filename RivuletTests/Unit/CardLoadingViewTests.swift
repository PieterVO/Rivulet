//
//  CardLoadingViewTests.swift
//  RivuletTests
//
//  Construction + layout coverage for the loading card panel. The panel
//  crashed on first construction in the wild (skeleton bar width
//  constraint activated before the bar joined the view hierarchy), so
//  these tests build a real instance and force a layout pass.
//

import XCTest
@testable import Rivulet

@MainActor
final class CardLoadingViewTests: XCTestCase {

    func test_initAndLayout_producesProportionalSkeletonBars() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let view = CardLoadingView(seriesLine: "Severance · S1 E5", title: "The Grim Barbarity of Optics")
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.setNeedsLayout()
        host.layoutIfNeeded()

        let bars = view.allSubviews.filter { $0.layer.cornerRadius == 6 && $0.bounds.height == 22 }
        XCTAssertEqual(bars.count, 2, "expected the two skeleton bars")

        let widths = bars.map(\.bounds.width).sorted()
        XCTAssertEqual(widths[0], 600 * 0.4, accuracy: 1, "short bar is 40% of the panel width")
        XCTAssertEqual(widths[1], 600 * 0.6, accuracy: 1, "tall bar is 60% of the panel width")
    }

    func test_initWithoutSeriesLine_doesNotCrash() {
        let view = CardLoadingView(seriesLine: nil, title: "Interstellar")
        view.layoutIfNeeded()
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap { $0.allSubviews } }
}
