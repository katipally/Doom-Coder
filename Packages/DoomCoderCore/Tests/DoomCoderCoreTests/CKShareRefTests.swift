// CKShareRefTests.swift — DoomCoderCore
// Unit tests for CKShareRef and Route encoding/decoding. Verifies that
// the Route enum's custom Codable correctly handles .iCloud (no payload)
// and .ckShare (payload-bearing) cases.

import XCTest
@testable import DoomCoderCore

final class CKShareRefTests: XCTestCase {

    func testCKShareRefRoundTrip() throws {
        let url = URL(string: "https://www.icloud.com/share/abc123#DEF")!
        let ref = CKShareRef(
            shareURL: url,
            ownerRecordName: "DoomCoderZone",
            containerIdentifier: "iCloud.com.doomcoder.app"
        )
        let data = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(CKShareRef.self, from: data)
        XCTAssertEqual(decoded, ref)
        XCTAssertEqual(decoded.shareURL, url)
    }

    func testRouteICloudEncodesAsTagOnly() throws {
        let route: Route = .iCloud
        let data = try JSONEncoder().encode(route)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"iCloud\""))
        XCTAssertFalse(json.contains("ref"))
        let decoded = try JSONDecoder().decode(Route.self, from: data)
        XCTAssertEqual(decoded, .iCloud)
    }

    func testRouteCKShareEncodesWithRef() throws {
        let ref = CKShareRef(
            shareURLString: "https://www.icloud.com/share/xyz",
            ownerRecordName: "DoomCoderZone",
            containerIdentifier: "iCloud.com.doomcoder.app"
        )
        let route: Route = .ckShare(ref)
        let data = try JSONEncoder().encode(route)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"ckShare\""))
        XCTAssertTrue(json.contains("\"ref\""))
        let decoded = try JSONDecoder().decode(Route.self, from: data)
        XCTAssertEqual(decoded, route)
    }

    func testRouteDisplayAndLabels() {
        XCTAssertEqual(Route.iCloud.shortLabel, "iCloud")
        XCTAssertEqual(Route.iCloud.displayName, "iCloud (same Apple ID)")
        XCTAssertEqual(Route.iCloud.isCrossAppleID, false)
    }

    func testCKShareRouteIsCrossAppleID() {
        let ref = CKShareRef(
            shareURLString: "https://example.com",
            ownerRecordName: "Zone",
            containerIdentifier: "container"
        )
        let route: Route = .ckShare(ref)
        XCTAssertEqual(route.shortLabel, "iCloud Share")
        XCTAssertTrue(route.isCrossAppleID)
    }

    func testCKShareRefInitRejectsEmpty() {
        let r = CKShareRef.make(shareURLString: "", containerIdentifier: "")
        XCTAssertNil(r)
    }

    func testCKShareRefInitAcceptsValid() {
        let r = CKShareRef.make(
            shareURLString: "https://www.icloud.com/share/foo",
            containerIdentifier: "iCloud.com.doomcoder.app"
        )
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.shareURL?.host, "www.icloud.com")
    }
}
