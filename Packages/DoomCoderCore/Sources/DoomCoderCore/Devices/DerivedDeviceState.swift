// DerivedDeviceState.swift — DoomCoderCore
//
// v7 revamp: connection state is no longer tracked by a hand-rolled state
// machine (ConnectionStateChange records + monotonic counters). It is DERIVED,
// on each side, from two observable facts:
//
//   1. Is there a pairing (a CKShare / same-iCloud link) to this peer?
//   2. Is the peer's DeviceRecord present in the zone, and how fresh is its
//      `lastSeen` heartbeat?
//
// Both sides compute the same function over the same shared zone, so the two
// device lists agree by construction.

import Foundation

public enum DerivedDeviceState: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// We have a pairing but the peer's DeviceRecord hasn't appeared yet
    /// (still accepting the share / writing its first heartbeat).
    case pending
    /// Peer DeviceRecord present with a fresh heartbeat.
    case active
    /// Peer DeviceRecord present but the heartbeat is stale (peer asleep /
    /// backgrounded / off-network). Still paired — just not reachable now.
    case offline
    /// The pairing is gone: peer DeviceRecord deleted or the shared zone was
    /// revoked. Terminal until the user re-pairs.
    case disconnected

    public var displayName: String {
        switch self {
        case .pending:      return "Connecting…"
        case .active:       return "Connected"
        case .offline:      return "Offline"
        case .disconnected: return "Disconnected"
        }
    }

    public var isLive: Bool { self == .active }

    /// Pure derivation. `hasPairing` = we hold a Connection/share to the peer;
    /// `peer` = the peer's DeviceRecord if present in the zone.
    public static func derive(
        hasPairing: Bool,
        peer: DeviceRecord?,
        onlineWindow: TimeInterval = 120,
        now: Date = Date()
    ) -> DerivedDeviceState {
        guard hasPairing else { return .disconnected }
        guard let peer else { return .pending }
        return now.timeIntervalSince(peer.lastSeen) <= onlineWindow ? .active : .offline
    }
}
