// V5SchemaTests.swift — DoomCoderCore
// v5 schema additions: Connection.pairingOrigin / stateChangeCounter /
// removedAt / shareAcceptedAt, PeerStatusRecord.routeAccountEmail /
// stateChangeCounter, ConnectionStateChangeRecord (new record type).
// All additive — must round-trip through Codable without data loss.

import XCTest
@testable import DoomCoderCore

final class V5SchemaTests: XCTestCase {

    // MARK: - Connection round-trips

    func testConnectionRoundTripsAllV5Fields() throws {
        let original = Connection(
            id: "conn-1",
            macDeviceId: "macABCDEFGHIJKLMNOPQRST",
            iosDeviceId: "iosABCDEFGHIJKLMNOPQRST",
            route: .iCloud,
            status: .active,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSyncAt: Date(timeIntervalSince1970: 1_700_000_500),
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 7,
            removedAt: nil,
            shareAcceptedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Connection.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testConnectionDefaultsToAutoOrigin() {
        let c = Connection(
            macDeviceId: "m", iosDeviceId: "i", route: .iCloud
        )
        XCTAssertEqual(c.pairingOrigin, .auto)
        XCTAssertEqual(c.stateChangeCounter, 1)
        XCTAssertNil(c.removedAt)
        XCTAssertNil(c.shareAcceptedAt)
    }

    func testConnectionIsAutoPaired() {
        let auto = Connection(
            macDeviceId: "m", iosDeviceId: "i", route: .iCloud,
            pairingOrigin: .auto
        )
        let qr = Connection(
            macDeviceId: "m", iosDeviceId: "i", route: .iCloud,
            pairingOrigin: .qr
        )
        XCTAssertTrue(auto.isAutoPaired)
        XCTAssertFalse(qr.isAutoPaired)
    }

    func testConnectionIsTombstoned() {
        var c = Connection(macDeviceId: "m", iosDeviceId: "i", route: .iCloud)
        XCTAssertFalse(c.isTombstoned)
        c.removedAt = Date()
        XCTAssertTrue(c.isTombstoned)
    }

    func testPairingOriginAllCasesHaveDisplayName() {
        for origin in PairingOrigin.allCases {
            XCTAssertFalse(origin.displayName.isEmpty, "\(origin) missing displayName")
            XCTAssertFalse(origin.systemImage.isEmpty, "\(origin) missing systemImage")
        }
    }

    // MARK: - PeerStatusRecord round-trips

    func testPeerStatusRecordRoundTripsV5Fields() throws {
        let original = PeerStatusRecord(
            iosDeviceId: "iosABCDEFGHIJKLMNOPQRST",
            name: "Yash's iPhone",
            model: "iPhone 17 Pro Max",
            systemName: "iOS 26.5",
            appVersion: "2.7.0 (12)",
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            route: "iCloud",
            macId: "macABCDEFGHIJKLMNOPQRST",
            shareURLString: nil,
            routeAccountEmail: "yash@icloud.com",
            stateChangeCounter: 5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PeerStatusRecord.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - ConnectionStateChangeRecord

    func testConnectionStateChangeRecordRoundTrip() throws {
        let original = ConnectionStateChangeRecord(
            macId: "macABCDEFGHIJKLMNOPQRST",
            iosDeviceId: "iosABCDEFGHIJKLMNOPQRST",
            state: "accepted",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            origin: "ios",
            routeTag: "iCloud",
            shareURLString: nil,
            routeAccountEmail: nil,
            oldIosDeviceId: nil,
            schemaVersion: 5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionStateChangeRecord.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testConnectionStateChangeRecordNameFormat() {
        let r = ConnectionStateChangeRecord(
            macId: "macABCDEFGHIJKLMNOPQRST",
            iosDeviceId: "iosABCDEFGHIJKLMNOPQRST",
            state: "accepted",
            origin: "ios",
            routeTag: "iCloud"
        )
        XCTAssertEqual(
            r.recordName(counter: 1),
            "CSC-macABCDEFGHIJKLMNOPQRST-iosABCDEFGHIJKLMNOPQRST-1"
        )
    }

    func testConnectionStateChangeCounterParse() {
        XCTAssertEqual(
            ConnectionStateChangeRecord.counterFromRecordName(
                "CSC-macABCDEFGHIJKLMNOPQRST-iosABCDEFGHIJKLMNOPQRST-42"
            ),
            42
        )
        XCTAssertNil(
            ConnectionStateChangeRecord.counterFromRecordName("garbage")
        )
        XCTAssertNil(
            ConnectionStateChangeRecord.counterFromRecordName(
                "CSC-mac-id-ios-id-notanumber"
            )
        )
    }

    func testStateConstants() {
        // The state field is a string for forward compatibility, but
        // the named enum cases must be stable so the receiving side
        // can switch on them.
        XCTAssertEqual(ConnectionStateChangeRecord.State.accepted.rawValue, "accepted")
        XCTAssertEqual(ConnectionStateChangeRecord.State.suspended.rawValue, "suspended")
        XCTAssertEqual(ConnectionStateChangeRecord.State.active.rawValue, "active")
        XCTAssertEqual(ConnectionStateChangeRecord.State.removed.rawValue, "removed")
        XCTAssertEqual(
            ConnectionStateChangeRecord.State.reinstallDetected.rawValue,
            "reinstall-detected"
        )
        // v5.1: same-iCloud gated flow.
        XCTAssertEqual(ConnectionStateChangeRecord.State.pending.rawValue, "pending")
        XCTAssertEqual(ConnectionStateChangeRecord.State.denied.rawValue, "denied")
    }

    func testConnectionStateChangeRecordCarriesIosUserRecordID() throws {
        // v5.1: the iOS side writes its own CloudKit user record
        // name into the CSC{pending} so the Mac can authoritatively
        // verify same-iCloud via CKRecord.creatorUserRecordID.
        let original = ConnectionStateChangeRecord(
            macId: "macABCDEFGHIJKLMNOPQRST",
            iosDeviceId: "iosABCDEFGHIJKLMNOPQRST",
            state: ConnectionStateChangeRecord.State.pending.rawValue,
            origin: "ios",
            routeTag: "iCloud",
            iosUserRecordID: "_abc123def"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionStateChangeRecord.self, from: data)
        XCTAssertEqual(decoded.iosUserRecordID, "_abc123def")
        XCTAssertEqual(decoded.state, "pending")
    }

    // MARK: - CloudKitConstants

    func testSchemaVersionIs5() {
        // v6: Mac-initiates rebuild bumped the schema (additive fields +
        // DiscoverableDevice record + CSC `requested` state).
        XCTAssertEqual(CloudKitConstants.schemaVersion, 6)
    }

    func testConnectionStateChangeRecordTypeIsRegistered() {
        XCTAssertEqual(
            CloudKitConstants.RecordType.connectionStateChange,
            "ConnectionStateChange"
        )
    }
}
