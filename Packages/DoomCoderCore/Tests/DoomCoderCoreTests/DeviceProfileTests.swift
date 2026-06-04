// DeviceProfileTests.swift — DoomCoderCore
// Unit tests for the Devices model: encode/decode round trip, default values,
// hashing, and identification uniqueness.

import XCTest
@testable import DoomCoderCore

final class DeviceProfileTests: XCTestCase {

    func testDeviceIDFactoryProduces22CharBase64URL() {
        let id = DeviceIDFactory.make()
        XCTAssertEqual(id.count, 22)
        XCTAssertTrue(DeviceIDFactory.isValid(id))
    }

    func testDeviceIDFactoryIsUnique() {
        let a = DeviceIDFactory.make()
        let b = DeviceIDFactory.make()
        let c = DeviceIDFactory.make()
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
        XCTAssertNotEqual(a, c)
    }

    func testDeviceIDValidation() {
        XCTAssertTrue(DeviceIDFactory.isValid("ABCDEFGHIJKLMNOPQRSTUV"))
        XCTAssertTrue(DeviceIDFactory.isValid("abcdefghijklmnopqrstuv"))
        XCTAssertTrue(DeviceIDFactory.isValid("0123456789-_-_-_-_-_-_"))
        XCTAssertFalse(DeviceIDFactory.isValid(""))
        XCTAssertFalse(DeviceIDFactory.isValid("short"))
        XCTAssertFalse(DeviceIDFactory.isValid("contains+plus+sign+here"))
        XCTAssertFalse(DeviceIDFactory.isValid("contains/slash/sign/here"))
    }

    func testDeviceProfileRoundTrip() throws {
        let original = DeviceProfile(
            name: "Yashwanth's MacBook Pro",
            kind: .mac,
            route: .iCloud,
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            capabilities: ["macOS", "push"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DeviceProfile.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testDeviceProfileDefaults() {
        let p = DeviceProfile(name: "Test", kind: .iphone)
        XCTAssertEqual(p.route, .iCloud)
        XCTAssertNil(p.lastSeen)
        XCTAssertTrue(p.capabilities.isEmpty)
    }

    func testDeviceKindSymbols() {
        XCTAssertEqual(DeviceKind.mac.symbolName, "macbook")
        XCTAssertEqual(DeviceKind.iphone.symbolName, "iphone.gen3")
        XCTAssertEqual(DeviceKind.ipad.symbolName, "ipad")
    }

    func testDeviceProfileStaleness() {
        let fresh = DeviceProfile(
            name: "fresh",
            kind: .mac,
            lastSeen: Date()
        )
        let stale = DeviceProfile(
            name: "stale",
            kind: .mac,
            lastSeen: Date(timeIntervalSinceNow: -1200)
        )
        let never = DeviceProfile(name: "never", kind: .mac, lastSeen: nil)
        XCTAssertTrue(fresh.isFresh)
        XCTAssertFalse(fresh.isStale)
        XCTAssertFalse(stale.isFresh)
        XCTAssertTrue(stale.isStale)
        XCTAssertTrue(never.isStale)
        XCTAssertFalse(never.isFresh)
    }

    func testDeviceProfileDisplayNameFallback() {
        let blank = DeviceProfile(name: "   ", kind: .mac)
        XCTAssertEqual(blank.displayName, "Mac")
        let named = DeviceProfile(name: "Work Laptop", kind: .mac)
        XCTAssertEqual(named.displayName, "Work Laptop")
    }
}
