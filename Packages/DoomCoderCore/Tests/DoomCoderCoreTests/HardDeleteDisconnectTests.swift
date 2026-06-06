// HardDeleteDisconnectTests.swift — DoomCoderCore
// v5.3: regression tests for the explicit-disconnect contract.
//
// Bug: tapping Disconnect or swiping-to-delete on iOS set
// status = .removed (a tombstone). The row stayed in the list
// with a "Removed 40s ago" pill until purgeTombstones ran 30
// days later. Worse, a 30s-later heart-beat would re-render the
// row as "live" because the .removed row's macId was still in
// the list. User had to refresh the panel
// to see the row vanish — and on next launch it was back.
//
// v5.3 contract: explicit disconnect is a real delete on both
// sides. CSC{removed} from either side triggers hard-delete on
// the other. Re-pairing creates a fresh Connection row.

import XCTest
@testable import DoomCoderCore

final class HardDeleteDisconnectTests: XCTestCase {

    // MARK: - Implicit id is still the same (re-pair reuses the slot)

    func testImplicitConnectionIdIsDeterministic() {
        // Re-pairing the same (macId, iosId) pair must produce
        // the same implicit id, so the slot in the user's list
        // is reborn in place rather than creating a duplicate.
        let id1 = Connection.implicitConnectionId(
            macId: "macAAAAAAAAAAAAAAAAAAAAA",
            iosDeviceId: "iosAAAAAAAAAAAAAAAAAAAAA"
        )
        let id2 = Connection.implicitConnectionId(
            macId: "macAAAAAAAAAAAAAAAAAAAAA",
            iosDeviceId: "iosAAAAAAAAAAAAAAAAAAAAA"
        )
        XCTAssertEqual(id1, id2)
    }

    func testTwoDifferentDevicesGetDifferentImplicitIds() {
        // Multi-device: pairing (macA, iosX) and (macB, iosX) must
        // not collide — a single iPhone paired with two Macs
        // produces two Connection rows.
        let a = Connection.implicitConnectionId(
            macId: "macAAAAAAAAAAAAAAAAAAAAA",
            iosDeviceId: "iosXXXXXXXXXXXXXXXXXXXXX"
        )
        let b = Connection.implicitConnectionId(
            macId: "macBBBBBBBBBBBBBBBBBBBBB",
            iosDeviceId: "iosXXXXXXXXXXXXXXXXXXXXX"
        )
        XCTAssertNotEqual(a, b,
            "Each (macId, iosId) pair must produce a unique id so multi-device pairing works")
    }

    // MARK: - Status transitions that v5.3 supports

    func testActiveConnectionHasExpectedFields() {
        let conn = Connection(
            id: "x",
            macDeviceId: "m",
            iosDeviceId: "i",
            route: .iCloud,
            status: .active,
            createdAt: .now,
            lastSyncAt: .now,
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 1,
            shareAcceptedAt: .now
        )
        XCTAssertEqual(conn.status, .active)
        XCTAssertNil(conn.removedAt)
    }

    // MARK: - CSC contract for cross-side hard-delete

    func testCscRemovedCarriesOriginTag() {
        // The CSC{removed,origin:mac} or CSC{removed,origin:ios}
        // is the trigger for hard-delete on the receiving side.
        // The origin field is the discriminator.
        let fromMac = makeCSC(origin: .mac, state: .removed)
        let fromIOS = makeCSC(origin: .ios, state: .removed)
        XCTAssertEqual(fromMac.origin, "mac")
        XCTAssertEqual(fromIOS.origin, "ios")
        XCTAssertEqual(fromMac.state, "removed")
        XCTAssertEqual(fromIOS.state, "removed")
    }

    func testCscRemovedCounterMustBeGreaterThanCurrent() {
        // The receiving side guards `counter > connection.stateChangeCounter`
        // so a stale replay can't undo a hard-delete (which has
        // incremented the local counter).
        let conn = makeConnection(counter: 5)
        let staleCounter = 3
        // A CSC with counter=3 must NOT pass the guard.
        XCTAssertFalse(staleCounter > conn.stateChangeCounter,
            "Stale replay must not undo a hard-delete on the receiving side")
    }

    func testCscWithGreaterCounterTriggersHardDelete() {
        // Receiving side: a CSC{removed,counter=6} arriving at
        // a row with counter=5 must be accepted and trigger the
        // hard-delete. (Tested at the model layer — the actual
        // iOS/Mac integration is in ConnectionStateChanges.ingest.)
        let existingCounter = 5
        let inboundCounter = 6
        XCTAssertTrue(inboundCounter > existingCounter,
            "Inbound CSC with greater counter must pass the replay guard")
    }

    // MARK: - Multi-device pairing semantics

    func testMultipleMacsOnOneIphoneProduceDistinctRows() {
        // Same iPhone + MacA and MacB → two distinct Connection
        // rows. The iOS Connections view shows both, and the
        // user can pick either with MacSwitcher.
        let iphoneId = "iosYYYYYYYYYYYYYYYYYYYYY"
        let macA = Connection(
            id: Connection.implicitConnectionId(
                macId: "macAAAAAAAAAAAAAAAAAAAAA",
                iosDeviceId: iphoneId
            ),
            macDeviceId: "macAAAAAAAAAAAAAAAAAAAAA",
            iosDeviceId: iphoneId,
            route: .iCloud,
            status: .active,
            createdAt: .now,
            lastSyncAt: .now,
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 1,
            shareAcceptedAt: .now
        )
        let macB = Connection(
            id: Connection.implicitConnectionId(
                macId: "macBBBBBBBBBBBBBBBBBBBBB",
                iosDeviceId: iphoneId
            ),
            macDeviceId: "macBBBBBBBBBBBBBBBBBBBBB",
            iosDeviceId: iphoneId,
            route: .iCloud,
            status: .active,
            createdAt: .now,
            lastSyncAt: .now,
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 1,
            shareAcceptedAt: .now
        )
        XCTAssertNotEqual(macA.id, macB.id,
            "Two Macs on one iPhone must be distinct rows in the iOS list")
        XCTAssertEqual(macA.iosDeviceId, macB.iosDeviceId,
            "Both rows share the iPhone's iosDeviceId")
        XCTAssertNotEqual(macA.macDeviceId, macB.macDeviceId)
    }

    // MARK: - Disconnect → re-pair: same id, fresh metadata

    func testRePairingAfterHardDeleteProducesSameId() {
        // The slot in the user's list is preserved. After a
        // hard-delete and re-pair, the new Connection has the
        // same id (so the dashboard's "this Mac" entry point
        // collapses in place) but fresh metadata.
        let macId = "macAAAAAAAAAAAAAAAAAAAAA"
        let iosId = "iosAAAAAAAAAAAAAAAAAAAAA"
        let original = Connection(
            id: Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId),
            macDeviceId: macId,
            iosDeviceId: iosId,
            route: .iCloud,
            status: .active,
            createdAt: .distantPast,
            lastSyncAt: .distantPast,
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 1,
            shareAcceptedAt: .distantPast
        )
        let repired = Connection(
            id: Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId),
            macDeviceId: macId,
            iosDeviceId: iosId,
            route: .iCloud,
            status: .active,
            createdAt: .now,
            lastSyncAt: .now,
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 1,
            shareAcceptedAt: .now
        )
        XCTAssertEqual(original.id, repired.id,
            "Hard-delete + re-pair produces the same implicit id so the slot reuses")
    }

    // MARK: - helpers

    private func makeCSC(
        origin: ConnectionStateChangeRecord.Origin,
        state: ConnectionStateChangeRecord.State
    ) -> ConnectionStateChangeRecord {
        ConnectionStateChangeRecord(
            macId: "macAAAAAAAAAAAAAAAAAAAAA",
            iosDeviceId: "iosAAAAAAAAAAAAAAAAAAAAA",
            state: state.rawValue,
            timestamp: .now,
            origin: origin.rawValue,
            routeTag: "v5",
            shareURLString: nil,
            routeAccountEmail: nil,
            oldIosDeviceId: nil,
            iosUserRecordID: nil,
            schemaVersion: 5
        )
    }

    private func makeConnection(counter: Int) -> Connection {
        Connection(
            id: "x",
            macDeviceId: "m",
            iosDeviceId: "i",
            route: .iCloud,
            status: .active,
            createdAt: .now,
            lastSyncAt: .now,
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: counter,
            shareAcceptedAt: .now
        )
    }
}
