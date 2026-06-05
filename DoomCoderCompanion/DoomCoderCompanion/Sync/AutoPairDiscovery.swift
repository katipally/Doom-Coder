// AutoPairDiscovery.swift — DoomCoder Companion
// v5: same-Apple-ID auto-pairing. The iOS companion used to be
// read-only and assumed the user would scan a QR or type a code
// to create a Connection. v5 changes that: when a MacStatus
// record arrives over the private iCloud database and there is
// no existing Connection for that Mac, we auto-create one with
// `pairingOrigin = .auto`. The user sees an inline banner
// explaining the situation and can disconnect at any time.
//
// Design constraints (from the audit, see plan §1.2 / §4.6):
//   • Idempotent: a second MacStatus heart-beat must NOT create
//     a duplicate Connection row. The deterministic id from
//     `Connection.implicitConnectionId(macId:iosDeviceId:)` makes
//     this trivially correct — the upsert collapses the row.
//   • Coalesce concurrent heartbeats: if two MacStatus records
//     arrive within 100ms (the engine's "sendChanges / fetchChanges
//     batched" pattern), we only kick off the auto-attach once.
//   • Skip when the user has explicitly removed the same Mac in
//     the last 5 minutes — the per-store tombstone field handles
//     this: the removed row is still in the local list, so
//     `connections.first(macId == ...)` is non-nil, and we don't
//     re-attach without an explicit user action.
//   • Don't re-attach across a reinstall until the iCloud
//     Keychain restore path has run (the helper self-promotes on
//     first read, so by the time we get here `current` is stable).
//
// Wired from `CompanionSyncEngine.handleFetched` `case macStatus`.
// No business logic in there besides "feed me the record"; all the
// policy lives here so the policy is testable in isolation.

import Foundation
import CloudKit
import DoomCoderCore

@MainActor
final class AutoPairDiscovery {
    static let shared = AutoPairDiscovery()
    private init() {}

    /// In-flight auto-attach operations keyed by macId. Prevents
    /// racing two MacStatus heart-beats into two Connection rows.
    private var inFlight: Set<String> = []

    /// macIds we've already auto-attached in this process lifetime.
    /// Combined with the in-flight set, this is the dedup gate.
    private var attached: Set<String> = []

    /// Five-minute cooldown after a user-driven remove. During
    /// this window we don't re-attach the same Mac.
    private var recentlyRemoved: [String: Date] = [:]

    private let cooldown: TimeInterval = 300

    /// Called from the CKSyncEngine's fetchedRecordZoneChanges path
    /// for every MacStatus that arrives. Cheap, idempotent.
    func consider(_ status: MacStatusRecord) {
        let macId = status.macId
        guard !macId.isEmpty else { return }
        // Skip if we already have a Connection (any status) for this Mac.
        if ConnectionStore.shared.connections.contains(where: { $0.macDeviceId == macId }) {
            return
        }
        // Skip if the user just removed this Mac.
        if let removedAt = recentlyRemoved[macId],
           Date().timeIntervalSince(removedAt) < cooldown {
            return
        }
        // Skip if we're already processing this Mac.
        guard !inFlight.contains(macId) else { return }
        inFlight.insert(macId)
        attached.insert(macId)

        Task { @MainActor in
            defer { inFlight.remove(macId) }
            await IOSPairingCoordinator.shared.autoAttach(macStatus: status)
        }
    }

    /// Called from the explicit user-driven remove path so we
    /// don't immediately re-attach via the next heart-beat.
    func markRecentlyRemoved(macId: String) {
        recentlyRemoved[macId] = Date()
        attached.remove(macId)
    }

    /// True if we have a pending or completed auto-attach for this Mac.
    /// Used by the UI to decide whether to show the inline banner.
    func isAutoAttached(macId: String) -> Bool {
        attached.contains(macId)
    }
}
