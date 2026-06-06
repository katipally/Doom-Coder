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

    // MARK: - v5 additive fields

    /// How this Connection came to be. Drives the UI label in
    /// DeviceDetailView ("QR code 4E7KQP" / "Auto (same Apple ID)"
    /// / "Typed code" / "Link"). Local-only — never sent over the
    /// wire; the Mac computes it on its side from the originating
    /// flow and so does iOS.
    public var pairingOrigin: PairingOrigin

    /// Monotonic counter incremented on every state transition.
    /// ConnectionStateChange records carry the counter value at the
    /// time of the transition so the receiving side can ignore
    /// out-of-order APNs replays. Starts at 1 when the Connection
    /// is first created (the initial `.pending`/`.active` transition).
    public var stateChangeCounter: Int

    /// Tombstone timestamp — set when status moves to `.removed`.
    /// The row is kept for 30 days so a re-scan of the same QR
    /// reactivates the existing id (no duplicate). Purged by
    /// `purgeRemoved(olderThan:)`.
    public var removedAt: Date?

    /// Set on the iOS side once `container.accept(metadata)` returns
    /// successfully. The Mac side back-fills this on the first
    /// ConnectionStateChange{accepted} it receives. Drives a small
    /// "Pairing completed" celebration animation.
    public var shareAcceptedAt: Date?

    /// v6: cached display identity of the *peer* device's iCloud account
    /// (the other side's name + email from CloudKit discoverability).
    /// Local-only render cache so device cards show "Yashwanth ·
    /// you@icloud.com" instantly; refreshed from heartbeats / share
    /// metadata. Nil → fall back to the route label ("Same/Different iCloud").
    public var peerAccountName: String?
    public var peerAccountEmail: String?

    public init(
        id: String = UUID().uuidString,
        macDeviceId: DeviceID,
        iosDeviceId: DeviceID,
        route: Route,
        status: ConnectionStatus = .pending,
        createdAt: Date = Date(),
        lastSyncAt: Date? = nil,
        ckShareRef: CKShareRef? = nil,
        pairingOrigin: PairingOrigin = .auto,
        stateChangeCounter: Int = 1,
        removedAt: Date? = nil,
        shareAcceptedAt: Date? = nil,
        peerAccountName: String? = nil,
        peerAccountEmail: String? = nil
    ) {
        self.id = id
        self.macDeviceId = macDeviceId
        self.iosDeviceId = iosDeviceId
        self.route = route
        self.status = status
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
        self.ckShareRef = ckShareRef
        self.pairingOrigin = pairingOrigin
        self.stateChangeCounter = stateChangeCounter
        self.removedAt = removedAt
        self.shareAcceptedAt = shareAcceptedAt
        self.peerAccountName = peerAccountName
        self.peerAccountEmail = peerAccountEmail
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

    /// Deterministic id for an implicit iCloud connection, keyed on both
    /// macId and iosDeviceId so multiple iOS devices on the same iCloud
    /// account each get their own row instead of overwriting each other.
    public static func implicitConnectionId(macId: DeviceID, iosDeviceId: DeviceID) -> String {
        return "implicit-\(macId)-\(iosDeviceId)"
    }

    /// Returns a copy of this Connection with a different id. Used for
    /// one-shot migrations that rewrite legacy id formats.
    public func withId(_ newId: String) -> Connection {
        Connection(
            id: newId,
            macDeviceId: macDeviceId,
            iosDeviceId: iosDeviceId,
            route: route,
            status: status,
            createdAt: createdAt,
            lastSyncAt: lastSyncAt,
            ckShareRef: ckShareRef,
            pairingOrigin: pairingOrigin,
            stateChangeCounter: stateChangeCounter,
            removedAt: removedAt,
            shareAcceptedAt: shareAcceptedAt,
            peerAccountName: peerAccountName,
            peerAccountEmail: peerAccountEmail
        )
    }

    /// True if this is a same-Apple-ID (private-zone) auto-paired
    /// Connection. The UI uses this to decide whether to show the
    /// "Auto (same Apple ID)" badge and to skip the explicit-disconnect
    /// confirmation copy that mentions a share being revoked.
    public var isAutoPaired: Bool {
        pairingOrigin == .auto
    }

    /// True if this Connection is in a terminal state. Mirrors
    /// `ConnectionStatus.isTerminal` but reads from the tombstone
    /// field so a re-fetched, status-restored row can be detected.
    public var isTombstoned: Bool { removedAt != nil }

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
