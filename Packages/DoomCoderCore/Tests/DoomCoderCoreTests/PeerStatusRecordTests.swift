// PeerStatusRecordTests.swift — DoomCoderCore
//
// Round-trip tests for PeerStatusRecord → CKRecord → PeerStatusRecord.
// Verifies the v2.7 wire format that the iOS app uses to announce
// itself to the Mac, and that the Mac's ingestion path expects.

import XCTest
#if canImport(CloudKit)
import CloudKit
#endif
@testable import DoomCoderCore

final class PeerStatusRecordTests: XCTestCase {

    func testRecordTypeIsPeerStatus() {
        XCTAssertEqual(PeerStatusRecord.recordType, "PeerStatus")
    }

    func testRecordIDIncludesBothIDs() {
        let rec = PeerStatusRecord(
            iosDeviceId: "ABCDEFGHIJKLMNOPQRSTUV",
            name: "Yash's iPhone",
            model: "iPhone",
            systemName: "iOS 26.4",
            appVersion: "2.7.0 (12)",
            route: "iCloud",
            macId: "MACID1234567890ABCDEFGH"
        )
        let name = rec.recordID.recordName
        XCTAssertTrue(name.hasPrefix("PeerStatus-MACID1234567890ABCDEFGH-"))
        XCTAssertTrue(name.hasSuffix("-ABCDEFGHIJKLMNOPQRSTUV"))
    }

    func testRecordIDFallsBackToUnknownWhenMacIdNil() {
        let rec = PeerStatusRecord(
            iosDeviceId: "ABCDEFGHIJKLMNOPQRSTUV",
            name: "Yash's iPhone",
            model: "iPhone",
            systemName: "iOS 26.4",
            appVersion: "2.7.0 (12)",
            route: "iCloud",
            macId: nil
        )
        XCTAssertTrue(rec.recordID.recordName.hasPrefix("PeerStatus-unknown-"))
    }

    #if canImport(CloudKit)
    func testCKRecordRoundTrip() {
        let original = PeerStatusRecord(
            iosDeviceId: "ABCDEFGHIJKLMNOPQRSTUV",
            name: "Yash's iPhone",
            model: "iPhone 17 Pro Max",
            systemName: "iOS 26.4",
            appVersion: "2.7.0 (12)",
            lastSeen: Date(timeIntervalSince1970: 1_750_000_000),
            route: "iCloud Share",
            macId: "MACID1234567890ABCDEFGH"
        )
        let ck = original.toCKRecord()
        let decoded = PeerStatusRecord(ck)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.iosDeviceId, original.iosDeviceId)
        XCTAssertEqual(decoded?.name,        original.name)
        XCTAssertEqual(decoded?.model,       original.model)
        XCTAssertEqual(decoded?.systemName,  original.systemName)
        XCTAssertEqual(decoded?.appVersion,  original.appVersion)
        XCTAssertEqual(decoded?.lastSeen.timeIntervalSince1970 ?? 0, original.lastSeen.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded?.route,       original.route)
        XCTAssertEqual(decoded?.macId,       original.macId)
    }

    func testCKRecordRoundTripWithNilMacId() {
        let original = PeerStatusRecord(
            iosDeviceId: "ABCDEFGHIJKLMNOPQRSTUV",
            name: "Yash's iPhone",
            model: "iPhone",
            systemName: "iOS 26.4",
            appVersion: "2.7.0 (12)",
            route: "iCloud",
            macId: nil
        )
        let ck = original.toCKRecord()
        // macId is explicitly nil, so the field should be nil
        XCTAssertNil(ck["macId"] as? String)
        let decoded = PeerStatusRecord(ck)
        XCTAssertNil(decoded?.macId)
    }

    func testInitRejectsWrongRecordType() {
        let rec = CKRecord(recordType: "NotPeerStatus")
        rec["iosDeviceId"] = "ABCDEFGHIJKLMNOPQRSTUV" as CKRecordValue
        XCTAssertNil(PeerStatusRecord(rec))
    }

    func testInitRejectsMissingIosDeviceId() {
        let rec = CKRecord(recordType: PeerStatusRecord.recordType)
        rec["name"] = "No ID" as CKRecordValue
        XCTAssertNil(PeerStatusRecord(rec))
    }
    #endif
}
