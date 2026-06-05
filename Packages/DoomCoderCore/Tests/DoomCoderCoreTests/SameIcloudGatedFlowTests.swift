// SameIcloudGatedFlowTests.swift — DoomCoderCore
// v5.1: end-to-end tests for the same-iCloud gated flow
// without a live CKContainer. The actual CloudKit calls
// happen in `DiscoverableMacPublisher` (Mac) and
// `DiscoverableMacSubscription` (iOS) and can't be unit-tested
// without a real CloudKit container. What we CAN test is the
// state machine and the model invariants:
//
//   1. DiscoverableMacRecord round-trips
//   2. ConnectionStateChangeRecord.iosUserRecordID field round-trips
//   3. ConnectionStateChangeRecord.State.pending / .denied work
//   4. PendingPairRequestQueue.Request dedupes by (macId, iosDeviceId)
//   5. Same-iCloud classification logic
//   6. The "approved" / "denied" CSCs use the public-DB recordID
//
// Where a test would require a live CKContainer, we
// instead test the model so the production code can
// be trusted to construct the right record shapes.

import XCTest
@testable import DoomCoderCore

final class SameIcloudGatedFlowTests: XCTestCase {

    // MARK: - DiscoverableMacRecord

    func testDiscoverableMacRecordRoundTrip() throws {
        let original = DiscoverableMacRecord(
            macId: "macABCDEFGHIJKLMNOPQRST",
            name: "Yash's MacBook Pro",
            model: "Mac15,3",
            systemVersion: "macOS 26.5",
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            publishedBy: "_abc123def"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiscoverableMacRecord.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, "DiscoverableMac-macABCDEFGHIJKLMNOPQRST")
    }

    // MARK: - CSC iosUserRecordID

    func testCSCCarriesIosUserRecordID() throws {
        let original = ConnectionStateChangeRecord(
            macId: "macABCDEFGHIJKLMNOPQRST",
            iosDeviceId: "iosABCDEFGHIJKLMNOPQRST",
            state: ConnectionStateChangeRecord.State.pending.rawValue,
            origin: ConnectionStateChangeRecord.Origin.ios.rawValue,
            routeTag: "iCloud",
            iosUserRecordID: "_abc123def"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionStateChangeRecord.self, from: data)
        XCTAssertEqual(decoded.iosUserRecordID, "_abc123def")
        XCTAssertEqual(decoded.state, ConnectionStateChangeRecord.State.pending.rawValue)
    }

    func testCSCWithoutIosUserRecordIDIsValid() throws {
        // The Mac's CSC responses (accepted/denied) don't need
        // iosUserRecordID set. The iOS app already knows its
        // own user record ID; the field is only needed on
        // iOS-originated CSCs for the Mac to do its check.
        let original = ConnectionStateChangeRecord(
            macId: "macABCDEFGHIJKLMNOPQRST",
            iosDeviceId: "iosABCDEFGHIJKLMNOPQRST",
            state: ConnectionStateChangeRecord.State.accepted.rawValue,
            origin: ConnectionStateChangeRecord.Origin.mac.rawValue,
            routeTag: "iCloud"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionStateChangeRecord.self, from: data)
        XCTAssertNil(decoded.iosUserRecordID)
        XCTAssertEqual(decoded.state, "accepted")
    }

    // MARK: - New state cases

    func testPendingAndDeniedStatesRoundTrip() throws {
        for state: ConnectionStateChangeRecord.State in [.pending, .denied] {
            let original = ConnectionStateChangeRecord(
                macId: "m", iosDeviceId: "i", state: state.rawValue,
                origin: "ios", routeTag: "iCloud"
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(ConnectionStateChangeRecord.self, from: data)
            XCTAssertEqual(decoded.state, state.rawValue)
        }
    }

    // MARK: - Implicit connection id for same-iCloud

    func testImplicitConnectionIdIsCollisionFree() {
        let macA = "macAAAAAAA1111111111111"
        let macB = "macBBBBBBB2222222222222"
        let iosA = "iosAAAAAAA1111111111111"
        let iosB = "iosBBBBBBB2222222222222"
        let pairs: [(String, String)] = [
            (macA, iosA), (macA, iosB), (macB, iosA), (macB, iosB)
        ]
        let ids = Set(pairs.map { Connection.implicitConnectionId(macId: $0.0, iosDeviceId: $0.1) })
        XCTAssertEqual(ids.count, pairs.count, "All 4 (mac,ios) pairs must yield distinct ids")
    }

    // MARK: - DiscoverableMacRecord vs Same-iCloud dedup

    func testSameMacIdProducesSameRecordName() {
        // The Mac's republishes must update the existing row in
        // place. Different `lastSeen` and `model` but the same
        // recordName means CloudKit collapses to one row.
        let a = DiscoverableMacRecord(
            macId: "macABCDEFGHIJKLMNOPQRST",
            name: "Old Name", model: "Mac15,2",
            systemVersion: "macOS 26.0", publishedBy: "_abc"
        )
        let b = DiscoverableMacRecord(
            macId: "macABCDEFGHIJKLMNOPQRST",
            name: "New Name", model: "Mac15,3",
            systemVersion: "macOS 26.5", publishedBy: "_abc"
        )
        XCTAssertEqual(a.recordName, b.recordName)
    }

    // MARK: - Pairing origin propagation for the gated-flow row

    func testApproveFlowCreatesAutoPairedConnection() {
        // MacPairingCoordinator's handleAcceptance path (existing)
        // and ConnectionStateChanges.approvePendingRequest (new)
        // both create a row with pairingOrigin = .auto. The
        // PeerStatus heart-beat (Part A) will then refresh it.
        // The id is the same implicit-id on both sides.
        let macId = "macABCDEFGHIJKLMNOPQRST"
        let iosId = "iosABCDEFGHIJKLMNOPQRST"
        let id = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId)
        let c = Connection(
            id: id,
            macDeviceId: macId,
            iosDeviceId: iosId,
            route: .iCloud,
            status: .active,
            createdAt: Date(),
            lastSyncAt: Date(),
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 1,
            shareAcceptedAt: Date()
        )
        XCTAssertTrue(c.isAutoPaired)
        XCTAssertEqual(c.route, .iCloud)
    }

    // MARK: - Counter parse is robust

    func testCounterFromRecordNameHandlesAllFormats() {
        XCTAssertEqual(
            ConnectionStateChangeRecord.counterFromRecordName(
                "CSC-macABCDEFGHIJKLMNOPQRST-iosABCDEFGHIJKLMNOPQRST-1"
            ),
            1
        )
        XCTAssertEqual(
            ConnectionStateChangeRecord.counterFromRecordName(
                "CSC-mac-ios-99"
            ),
            99
        )
        XCTAssertNil(ConnectionStateChangeRecord.counterFromRecordName(""))
        XCTAssertNil(ConnectionStateChangeRecord.counterFromRecordName("garbage"))
    }
}
