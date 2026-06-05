// AutoAttachTests.swift — DoomCoderCore
// v5.1: tests for the auto-attach path that makes the Mac see a
// same-Apple-ID iOS device immediately on the first heart-beat.
// The actual ingestPeerStatus method lives on the Mac and
// requires a live CKContainer, so we test the model invariants
// the path depends on:
//   1. Connection.implicitConnectionId is stable + collision-free
//      across the same-Apple-ID multi-device case
//   2. Connection.pairingOrigin defaults to .auto
//   3. Connection.isAutoPaired is correct
//   4. Connection can be serialised and round-tripped with
//      pairingOrigin = .auto

import XCTest
@testable import DoomCoderCore

final class AutoAttachTests: XCTestCase {

    func testImplicitConnectionIdCollapsesSameAccountPair() {
        let macId = "macABCDEFGHIJKLMNOPQRST"
        let iosId = "iosABCDEFGHIJKLMNOPQRST"
        let a = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId)
        let b = Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId)
        XCTAssertEqual(a, b)
        // First render: Connection is created with this deterministic
        // id, so iOS and Mac sides both compute the same id and
        // upsert to the same row.
    }

    func testTwoIOSDevicesOnSameMacGetDifferentImplicitIds() {
        let macId = "macABCDEFGHIJKLMNOPQRST"
        let ios1 = "IOS1IOS1IOS1IOS1IOS1IOS"
        let ios2 = "IOS2IOS2IOS2IOS2IOS2IOS"
        let a = Connection.implicitConnectionId(macId: macId, iosDeviceId: ios1)
        let b = Connection.implicitConnectionId(macId: macId, iosDeviceId: ios2)
        XCTAssertNotEqual(a, b,
            "Two iOS devices on the same Mac must not collide on the implicit id")
    }

    func testTwoMacsOnSameIOSDeviceGetDifferentImplicitIds() {
        let iosId = "iosABCDEFGHIJKLMNOPQRST"
        let mac1 = "MAC1MAC1MAC1MAC1MAC1MAC"
        let mac2 = "MAC2MAC2MAC2MAC2MAC2MAC"
        let a = Connection.implicitConnectionId(macId: mac1, iosDeviceId: iosId)
        let b = Connection.implicitConnectionId(macId: mac2, iosDeviceId: iosId)
        XCTAssertNotEqual(a, b,
            "Two Macs on the same iOS device must not collide on the implicit id")
    }

    func testAutoAttachConnectionHasCorrectFields() {
        // The Mac-side auto-attach path (CloudKitPusher.ingestPeerStatus
        // → same-account branch) constructs a Connection with
        // pairingOrigin = .auto, route = .iCloud, no ckShareRef.
        // The implicit id matches what iOS computes so the row
        // collapses on first round-trip.
        let macId = "macABCDEFGHIJKLMNOPQRST"
        let iosId = "iosABCDEFGHIJKLMNOPQRST"
        let c = Connection(
            id: Connection.implicitConnectionId(macId: macId, iosDeviceId: iosId),
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
        XCTAssertFalse(c.route.isCrossAppleID)
        XCTAssertNil(c.ckShareRef)
        XCTAssertEqual(c.stateChangeCounter, 1)
        XCTAssertNotNil(c.shareAcceptedAt)
    }

    func testAutoAttachConnectionRoundTrips() throws {
        let c = Connection(
            macDeviceId: "macABCDEFGHIJKLMNOPQRST",
            iosDeviceId: "iosABCDEFGHIJKLMNOPQRST",
            route: .iCloud,
            status: .active,
            lastSyncAt: Date(),
            ckShareRef: nil,
            pairingOrigin: .auto,
            stateChangeCounter: 1
        )
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(Connection.self, from: data)
        XCTAssertEqual(decoded, c)
        XCTAssertEqual(decoded.pairingOrigin, .auto)
    }

    func testPairingOriginAutoRejectsExplicitOrigins() {
        // v5.1: isAutoPaired must be true ONLY for .auto. .reinstall
        // (which re-uses the implicit-id path during a same-iOS-id
        // reinstall) is NOT considered auto.
        for origin in [PairingOrigin.qr, .code, .link, .reinstall, .imported] {
            let c = Connection(
                macDeviceId: "m", iosDeviceId: "i", route: .iCloud,
                pairingOrigin: origin
            )
            XCTAssertFalse(c.isAutoPaired,
                "\(origin) should not be considered auto-paired")
        }
    }
}
