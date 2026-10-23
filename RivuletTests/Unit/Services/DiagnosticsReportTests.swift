// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class DiagnosticsReportTests: XCTestCase {
    /// The attachment is dropped when the report holds anything JSONSerialization rejects.
    func test_collect_isValidJSON() {
        let sections = DiagnosticsReport.collect(window: nil)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(sections))
        XCTAssertNotNil(sections["top_shelf"] as? [String: Any])
    }
}
