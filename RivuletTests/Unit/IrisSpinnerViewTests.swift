import XCTest
@testable import Rivulet

@MainActor
final class IrisSpinnerViewTests: XCTestCase {

    func test_defaultAndLoadingSizes_stayCircular() {
        for (diameter, stroke) in [(CGFloat(64), CGFloat(8)), (CGFloat(110), CGFloat(9))] {
            let spinner = IrisSpinnerView(diameter: diameter, stroke: stroke)
            spinner.layoutIfNeeded()
            XCTAssertEqual(spinner.bounds.width, diameter)
            XCTAssertEqual(spinner.bounds.height, diameter)
        }
    }

    func test_stretchingHost_cannotDistortTheRing() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        let spinner = IrisSpinnerView(diameter: 110, stroke: 9)
        host.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        host.layoutIfNeeded()
        XCTAssertEqual(spinner.bounds.size, CGSize(width: 110, height: 110))
    }
}
