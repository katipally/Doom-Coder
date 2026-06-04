// ConnectionStatusTests.swift — DoomCoderCore
// Unit tests for the connection state machine. Verifies that legal
// transitions succeed and that .removed is terminal.

import XCTest
@testable import DoomCoderCore

final class ConnectionStatusTests: XCTestCase {

    func testDisplayNames() {
        XCTAssertEqual(ConnectionStatus.pending.displayName, "Pending")
        XCTAssertEqual(ConnectionStatus.active.displayName, "Connected")
        XCTAssertEqual(ConnectionStatus.suspended.displayName, "Suspended")
        XCTAssertEqual(ConnectionStatus.removed.displayName, "Removed")
    }

    func testLiveFlag() {
        XCTAssertFalse(ConnectionStatus.pending.isLive)
        XCTAssertTrue(ConnectionStatus.active.isLive)
        XCTAssertFalse(ConnectionStatus.suspended.isLive)
        XCTAssertFalse(ConnectionStatus.removed.isLive)
    }

    func testTerminalFlag() {
        XCTAssertFalse(ConnectionStatus.pending.isTerminal)
        XCTAssertFalse(ConnectionStatus.active.isTerminal)
        XCTAssertFalse(ConnectionStatus.suspended.isTerminal)
        XCTAssertTrue(ConnectionStatus.removed.isTerminal)
    }

    func testLegalTransitionsFromPending() {
        XCTAssertEqual(ConnectionStatus.pending.transitioned(to: .active), .active)
        XCTAssertEqual(ConnectionStatus.pending.transitioned(to: .pending), .pending)
        XCTAssertEqual(ConnectionStatus.pending.transitioned(to: .removed), .removed)
        XCTAssertNil(ConnectionStatus.pending.transitioned(to: .suspended))
    }

    func testLegalTransitionsFromActive() {
        XCTAssertEqual(ConnectionStatus.active.transitioned(to: .suspended), .suspended)
        XCTAssertEqual(ConnectionStatus.active.transitioned(to: .active), .active)
        XCTAssertEqual(ConnectionStatus.active.transitioned(to: .removed), .removed)
        XCTAssertNil(ConnectionStatus.active.transitioned(to: .pending))
    }

    func testLegalTransitionsFromSuspended() {
        XCTAssertEqual(ConnectionStatus.suspended.transitioned(to: .active), .active)
        XCTAssertEqual(ConnectionStatus.suspended.transitioned(to: .suspended), .suspended)
        XCTAssertEqual(ConnectionStatus.suspended.transitioned(to: .removed), .removed)
        XCTAssertNil(ConnectionStatus.suspended.transitioned(to: .pending))
    }

    func testRemovedIsTerminal() {
        XCTAssertNil(ConnectionStatus.removed.transitioned(to: .pending))
        XCTAssertNil(ConnectionStatus.removed.transitioned(to: .active))
        XCTAssertNil(ConnectionStatus.removed.transitioned(to: .suspended))
        XCTAssertNil(ConnectionStatus.removed.transitioned(to: .removed))
    }
}
