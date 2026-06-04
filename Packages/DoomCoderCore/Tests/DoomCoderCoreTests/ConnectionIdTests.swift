// ConnectionIdTests.swift — DoomCoderCore
//
// v2.8: deterministic-id tests. The id is derived from the route's
// natural CloudKit identity so re-pairing the same share (or
// re-fetching the same MacStatus) collapses to the same id.

import XCTest
@testable import DoomCoderCore

final class ConnectionIdTests: XCTestCase {

    func testImplicitIdIsMacIdBased() {
        let macId = "ABCDEFGHIJKLMNOPQRSTUV"
        let id = Connection.implicitConnectionId(macId: macId)
        XCTAssertEqual(id, "implicit-ABCDEFGHIJKLMNOPQRSTUV")
    }

    func testImplicitIdIsStable() {
        let macId = "ABCDEFGHIJKLMNOPQRSTUV"
        let a = Connection.implicitConnectionId(macId: macId)
        let b = Connection.implicitConnectionId(macId: macId)
        XCTAssertEqual(a, b)
    }

    func testCKShareIdIsShareUrlHash() {
        let ref = CKShareRef(
            shareURLString: "https://www.icloud.com/share/abc123",
            ownerRecordName: "DoomCoderShare-XYZ",
            containerIdentifier: "iCloud.com.doomcoder.app"
        )
        let id = Connection.deterministicId(for: .ckShare(ref))
        XCTAssertTrue(id.hasPrefix("share-"))
        // 22 chars after the prefix (matches DeviceIDFactory length)
        let suffix = String(id.dropFirst("share-".count))
        XCTAssertEqual(suffix.count, 22)
    }

    func testCKShareIdIsStable() {
        let ref = CKShareRef(
            shareURLString: "https://www.icloud.com/share/abc123",
            ownerRecordName: "DoomCoderShare-XYZ",
            containerIdentifier: "iCloud.com.doomcoder.app"
        )
        let a = Connection.deterministicId(for: .ckShare(ref))
        let b = Connection.deterministicId(for: .ckShare(ref))
        XCTAssertEqual(a, b)
    }

    func testDifferentShareUrlsProduceDifferentIds() {
        let refA = CKShareRef(
            shareURLString: "https://www.icloud.com/share/abc123",
            ownerRecordName: "DoomCoderShare-XYZ",
            containerIdentifier: "iCloud.com.doomcoder.app"
        )
        let refB = CKShareRef(
            shareURLString: "https://www.icloud.com/share/xyz789",
            ownerRecordName: "DoomCoderShare-XYZ",
            containerIdentifier: "iCloud.com.doomcoder.app"
        )
        let a = Connection.deterministicId(for: .ckShare(refA))
        let b = Connection.deterministicId(for: .ckShare(refB))
        XCTAssertNotEqual(a, b)
    }

    func testIcloudRouteHasPlaceholder() {
        // The implicit-route case needs the macId to be useful, but
        // callers should use `implicitConnectionId(macId:)` directly.
        // This test pins the current behavior so a future refactor
        // doesn't accidentally change the contract.
        let id = Connection.deterministicId(for: .iCloud)
        XCTAssertEqual(id, "implicit-unknown")
    }

    func testCKShareIdIsURLLengthIndependent() {
        // A short URL and a long URL should still produce ids of the
        // same length (22 chars after the prefix).
        let shortRef = CKShareRef(
            shareURLString: "https://www.icloud.com/share/abc",
            ownerRecordName: "X", containerIdentifier: "Y"
        )
        let longRef = CKShareRef(
            shareURLString: "https://www.icloud.com/share/" + String(repeating: "z", count: 1024),
            ownerRecordName: "X", containerIdentifier: "Y"
        )
        let shortId = Connection.deterministicId(for: .ckShare(shortRef))
        let longId = Connection.deterministicId(for: .ckShare(longRef))
        let shortSuffix = String(shortId.dropFirst("share-".count))
        let longSuffix = String(longId.dropFirst("share-".count))
        XCTAssertEqual(shortSuffix.count, longSuffix.count)
        XCTAssertNotEqual(shortId, longId)
    }
}
