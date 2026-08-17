// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The once-per-outage gate behind the offline popup. A flapping connection
/// must not stack popups, and a second outage later in the session must still
/// be announced.
final class ConnectionAlertGateTests: XCTestCase {

    func test_connected_neverPresents() {
        var gate = ConnectionAlertGate()
        XCTAssertFalse(gate.shouldPresent(isConnected: true))
        XCTAssertFalse(gate.shouldPresent(isConnected: true))
    }

    func test_firstOffline_presentsOnce() {
        var gate = ConnectionAlertGate()
        XCTAssertTrue(gate.shouldPresent(isConnected: false))
        XCTAssertFalse(gate.shouldPresent(isConnected: false), "repeat offline checks must not stack popups")
        XCTAssertFalse(gate.shouldPresent(isConnected: false))
    }

    func test_reconnect_rearmsForTheNextOutage() {
        var gate = ConnectionAlertGate()
        XCTAssertTrue(gate.shouldPresent(isConnected: false))
        XCTAssertFalse(gate.shouldPresent(isConnected: true), "recovery itself is not an announcement")
        XCTAssertTrue(gate.shouldPresent(isConnected: false), "a second outage is a new outage")
    }
}
