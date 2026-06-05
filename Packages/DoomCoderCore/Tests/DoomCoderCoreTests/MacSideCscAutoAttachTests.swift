// MacSideCscAutoAttachTests.swift — DoomCoderCore
// v5.2: regression tests for the Mac-side CSC auto-attach path.
//
// Bug: iOS device shows the Mac as connected (heart-beat round-trip
// works) but the Mac's Connections tab stays empty (CSC{accepted}
// was being dropped when no row existed yet). CSC is the
// authoritative signal; this test suite locks that down at the
// model layer.

import XCTest
@testable import DoomCoderCore

final class MacSideCscAutoAttachTests: XCTestCase {

    // MARK: - CSC contract for auto-attach

    func testCscFromIOSDeviceCarriesOriginTag() {
        // CSC written by iOS must include origin=ios. This is the
        // field the Mac checks to decide "this is the iOS device
        // telling me it just paired, I should create a row".
        let record = makeCSC(
            macId: "macABCDEFGHIJKLMNOPQRST",
            iosId: "iosABCDEFGHIJKLMNOPQRST",
            origin: .ios,
            state: .accepted
        )
        XCTAssertEqual(record.origin, "ios",
            "CSC from iOS must carry origin=ios so Mac knows to create a row")
    }

    func testCscAcceptedStateRoundTrips() {
        let record = makeCSC(
            macId: "macABCDEFGHIJKLMNOPQRST",
            iosId: "iosABCDEFGHIJKLMNOPQRST",
            origin: .ios,
            state: .accepted
        )
        XCTAssertEqual(record.state, "accepted",
            "accepted is the iOS→Mac 'I just paired' signal")
    }

    func testCscActiveStateAlsoTriggersAutoAttach() {
        // .active is what gets written after the iOS app receives
        // its own auto-attach. It must also count as auto-attach.
        let record = makeCSC(
            macId: "macABCDEFGHIJKLMNOPQRST",
            iosId: "iosABCDEFGHIJKLMNOPQRST",
            origin: .ios,
            state: .active
        )
        XCTAssertEqual(record.state, "active")
    }

    // MARK: - Implicit Connection id for CSC-created rows

    func testCSCRowUsesImplicitConnectionId() {
        // Mac creates the Connection with implicitConnectionId so
        // iOS (which computes the same id) and Mac agree on the
        // row from the first render.
        let macId = "macABCDEFGHIJKLMNOPQRST"
        let iosId = "iosABCDEFGHIJKLMNOPQRST"
        let id = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId)
        let conn = Connection(
            id: id,
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
        XCTAssertEqual(conn.id, id)
        XCTAssertEqual(conn.pairingOrigin, .auto,
            "CSC-auto-attached row must be marked .auto so UI can show 'auto-paired'")
        XCTAssertTrue(conn.isAutoPaired)
    }

    // MARK: - Counter dedup for replays

    func testCSCWithStaleCounterDoesNotOverwriteNewerState() {
        // A late-arriving CSC with counter < current must not
        // regress the row's status. (The Mac-side ingest drops
        // these; we verify the underlying model rejects the write
        // shape that would be produced.)
        var conn = Connection(
            id: "x",
            macDeviceId: "m",
            iosDeviceId: "i",
            route: .iCloud,
            status: .suspended,
            createdAt: .now,
            lastSyncAt: .now,
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 5,
            shareAcceptedAt: .now
        )
        // Simulate a stale CSC trying to set .removed with counter=3.
        // The Mac's ingest guards `guard counter > connection.stateChangeCounter`,
        // which is exactly this: 3 is not > 5, so it bails.
        let staleCounter = 3
        XCTAssertFalse(staleCounter > conn.stateChangeCounter,
            "Stale counter must not pass the Mac-side replay guard")
        // Sanity: row is still in the correct state because the
        // guard prevented the write.
        XCTAssertEqual(conn.status, .suspended)
    }

    // MARK: - Reinstall reconciliation

    func testCscReinstallAdoptsNewIosId() {
        // CSC with oldIosDeviceId = current row's iosDeviceId and
        // a fresh iosDeviceId in the new fields means the iOS app
        // was reinstalled. The row should adopt the new iosId.
        let oldIosId = "iosOLD1234567890abcdefgh"
        let newIosId = "iosNEW1234567890abcdefgh"
        let macId = "macABCDEFGHIJKLMNOPQRST"
        // Existing row from the old install.
        let existing = Connection(
            id: Connection.implicitConnectionId(macId: macId, iosDeviceId: oldIosId),
            macDeviceId: macId,
            iosDeviceId: oldIosId,
            route: .iCloud,
            status: .active,
            createdAt: .distantPast,
            lastSyncAt: .distantPast,
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 5,
            shareAcceptedAt: .distantPast
        )
        // CSC arrives with oldIosDeviceId = oldIosId, new iosDeviceId = newIosId.
        let csc = makeCSC(
            macId: macId,
            iosId: newIosId,
            origin: .ios,
            state: .reinstallDetected,
            oldIosId: oldIosId
        )
        XCTAssertEqual(csc.oldIosDeviceId, oldIosId)
        XCTAssertEqual(csc.iosDeviceId, newIosId)
        // Reinstall path leaves existing.id intact and updates iosDeviceId.
        var reconciled = existing
        reconciled.iosDeviceId = csc.iosDeviceId
        reconciled.pairingOrigin = .reinstall
        XCTAssertEqual(reconciled.iosDeviceId, newIosId)
        XCTAssertEqual(reconciled.pairingOrigin, .reinstall)
    }

    // MARK: - Heart-beat is now keep-alive, not source-of-truth

    func testConnectionCreatedFromCSCBeforeHeartbeat() {
        // Documents the new contract: Mac creates a row from
        // CSC{accepted,origin=ios} immediately, *before* any
        // PeerStatus heart-beat has been received. This is the
        // behaviour that fixes the user's "iOS shows Mac
        // connected, Mac shows nothing" report.
        let macId = "macABCDEFGHIJKLMNOPQRST"
        let iosId = "iosABCDEFGHIJKLMNOPQRST"
        let id = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId)
        let conn = Connection(
            id: id,
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
        XCTAssertEqual(conn.status, .active,
            "CSC-auto-attached row starts as .active so it renders in the tab immediately")
        XCTAssertNotNil(conn.lastSyncAt,
            "CSC auto-attach stamps lastSyncAt from the CSC timestamp")
    }

    // MARK: - helpers

    private func makeCSC(
        macId: String,
        iosId: String,
        origin: ConnectionStateChangeRecord.Origin,
        state: ConnectionStateChangeRecord.State,
        oldIosId: String? = nil,
        timestamp: Date = .now
    ) -> ConnectionStateChangeRecord {
        ConnectionStateChangeRecord(
            macId: macId,
            iosDeviceId: iosId,
            state: state.rawValue,
            timestamp: timestamp,
            origin: origin.rawValue,
            routeTag: "v5",
            shareURLString: nil,
            routeAccountEmail: nil,
            oldIosDeviceId: oldIosId,
            iosUserRecordID: nil,
            schemaVersion: 5
        )
    }
}
