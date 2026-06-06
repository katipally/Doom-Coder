// ConnectionStateChanges.swift — DoomCoder Mac
//
// v7 revamp: NEUTRALIZED. Connection state is no longer driven by
// ConnectionStateChange (CSC) records. It is DERIVED from which
// DeviceRecords are present in DoomCoderZone and how fresh their
// `lastSeen` heartbeat is (see `DerivedDeviceState` /
// `IosDeviceProfileCache.derivedState(for:)`).
//
// The writer + observer have been removed. This shim remains only so the
// few remaining call sites compile while the rest of the codebase is
// migrated; every method is a no-op. `CSCMacPendingCache` is likewise an
// inert stub kept so the engine delegate's legacy CSC branch (now dead)
// still type-checks. No CSC record is ever written or ingested.

import Foundation
import CloudKit
import DoomCoderCore

@MainActor
final class ConnectionStateChanges {
    static let shared = ConnectionStateChanges()
    private init() {}

    /// No-op. Pairing acceptance and disconnect are now expressed by the
    /// presence (or absence) of the peer's DeviceRecord in the zone.
    func publish(
        state: Any,
        for connection: Connection,
        origin: Any,
        oldIosDeviceId: String? = nil,
        emailHint: String? = nil
    ) async {}

    /// No-op. CSC records are no longer ingested.
    func ingest(_ record: CKRecord) {}
}

// MARK: - Pending record cache (inert stub)

@MainActor
final class CSCMacPendingCache {
    static let shared = CSCMacPendingCache()
    private init() {}

    func buildCKRecord(for recordID: CKRecord.ID) -> CKRecord? { nil }
    func didSave(_ record: CKRecord) {}
}
