// Connection.swift — DoomCoderCore
// A pairing record describing one Mac <-> one iOS device. Stored locally on
// each side. The status is computed by each side and may temporarily diverge
// (e.g. iOS has network but Mac is offline). The Connection is the
// authoritative source for "should this Mac push to this iOS device?"
//
// v2.8: deterministic-id constructors. The id is derived from the
// natural CloudKit identity (share URL for explicit pairs, macId for
// implicit pairs) so re-pairing the same share or re-fetching the same
// MacStatus does not create duplicate rows.

import Foundation
import CryptoKit

public struct Connection: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public var macDeviceId: DeviceID
    public var iosDeviceId: DeviceID
    public var route: Route
    public var status: ConnectionStatus
    public var createdAt: Date
    public var lastSyncAt: Date?
    public var ckShareRef: CKShareRef?

    public init(
        id: String = UUID().uuidString,
        macDeviceId: DeviceID,
        iosDeviceId: DeviceID,
        route: Route,
        status: ConnectionStatus = .pending,
        createdAt: Date = Date(),
        lastSyncAt: Date? = nil,
        ckShareRef: CKShareRef? = nil
    ) {
        self.id = id
        self.macDeviceId = macDeviceId
        self.iosDeviceId = iosDeviceId
        self.route = route
        self.status = status
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
        self.ckShareRef = ckShareRef
    }

    /// Connection is fresh if lastSyncAt is within the freshness window.
    public var isFresh: Bool {
        guard let lastSyncAt else { return false }
        return Date().timeIntervalSince(lastSyncAt) < 180
    }

    /// Connection is stale (visible but hasn't checked in for 10+ minutes).
    public var isStale: Bool {
        guard let lastSyncAt else { return true }
        return Date().timeIntervalSince(lastSyncAt) > 600
    }

    // MARK: - Deterministic id (v2.8)

    /// Derives a stable id from the route. Re-pairing the same share,
    /// re-fetching the same MacStatus, or re-running the implicit
    /// connection auto-register all produce the same id — so the
    /// SQLite / in-memory upsert collapses the duplicates.
    ///
    /// Format: `"share-<sha256(shareURL).prefix(22)>"` for ckShare,
    /// `"implicit-<macId>"` for implicit. The hash keeps the id
    /// length bounded regardless of how long the share URL gets.
    public static func deterministicId(for route: Route) -> String {
        switch route {
        case .iCloud:
            // .iCloud doesn't carry a share URL; use implicitConnectionId(macId:)
            // at the call site when the macId is known.
            return "implicit-unknown"
        case .ckShare(let ref):
            return "share-" + Self.shortHash(of: ref.shareURLString)
        }
    }

    /// Deterministic id for an implicit iCloud connection, keyed on macId.
    public static func implicitConnectionId(macId: DeviceID) -> String {
        return "implicit-\(macId)"
    }

    private static func shortHash(of s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        // First 16 bytes -> 22-char base64url (no padding). Mirrors the
        // DeviceIDFactory.make() format for visual consistency.
        return Data(digest.prefix(16)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
