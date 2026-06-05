// DiscoverableMacRecordTests.swift — DoomCoderCore
// v5.1: tests for the public-DB record type that powers the
// "Same iCloud" discoverable list in the iOS Add Mac sheet.

import XCTest
@testable import DoomCoderCore

final class DiscoverableMacRecordTests: XCTestCase {

    func testRecordNameIsStable() {
        let r = DiscoverableMacRecord(
            macId: "macABCDEFGHIJKLMNOPQRST",
            name: "Yash's MacBook Pro",
            model: "Mac15,3",
            systemVersion: "macOS 26.5",
            publishedBy: "_abc123"
        )
        XCTAssertEqual(r.recordName, "DiscoverableMac-macABCDEFGHIJKLMNOPQRST")
    }

    func testSameMacIdProducesSameRecordName() {
        // Re-publishes must collapse to the same record name so
        // CloudKit updates the existing row in place rather than
        // creating a new one.
        let a = DiscoverableMacRecord(
            macId: "macABCDEFGHIJKLMNOPQRST",
            name: "Yash's MacBook Pro", model: "Mac15,3",
            systemVersion: "macOS 26.5", publishedBy: "_abc123"
        )
        let b = DiscoverableMacRecord(
            macId: "macABCDEFGHIJKLMNOPQRST",
            name: "Yash's MacBook Pro (renamed)", model: "Mac15,3",
            systemVersion: "macOS 26.5", publishedBy: "_abc123"
        )
        XCTAssertEqual(a.recordName, b.recordName)
    }

    func testCodableRoundTrip() throws {
        let original = DiscoverableMacRecord(
            macId: "macABCDEFGHIJKLMNOPQRST",
            name: "Yash's MacBook Pro",
            model: "Mac15,3",
            systemVersion: "macOS 26.5",
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            publishedBy: "_abc123"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiscoverableMacRecord.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testSchemaVersionIsAtLeast5() {
        // v5.1: bumped in the same release as DiscoverableMac.
        XCTAssertGreaterThanOrEqual(CloudKitConstants.schemaVersion, 5)
    }

    func testRecordTypeIsRegistered() {
        XCTAssertEqual(
            CloudKitConstants.RecordType.discoverableMac,
            "DiscoverableMac"
        )
    }
}
