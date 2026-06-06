// PeerStatusPublisher.swift — DoomCoder Companion
//
// v7: publishes this iPhone's own `DeviceRecord(role: .ios)` — the single
// presence/profile record — into the Mac's shared DoomCoderZone on a light
// foreground heartbeat. Replaces the v2.x PeerStatusRecord writer.
//
// "Which database" is the ONLY same/different-iCloud branch:
//   • Same iCloud  → the iPhone shares the Mac's PRIVATE zone, so it enqueues
//     its DeviceRecord through CompanionSyncEngine (private DB) via
//     `nextRecordZoneChangeBatch`. zoneOwner = CKCurrentUserDefaultName.
//   • Different iCloud → the iPhone has the Mac's zone in its SHARED database
//     (after accepting the CKShare), so it enqueues its DeviceRecord through
//     SharedDatabaseSync's engine (shared DB) via `nextRecordZoneChangeBatch`,
//     using the Mac's owner record name as the zoneOwner. NO direct
//     CKModifyRecordsOperation — the engine owns the write so recordChangeTag
//     is managed cleanly (single writer → clean UPDATEs).

import Foundation
import CloudKit
import UIKit
import Observation
import DoomCoderCore

@MainActor
final class PeerStatusPublisher {

    static let shared = PeerStatusPublisher()

    private var lastPublishedAt: Date = .distantPast
    private var heartbeatTimer: Timer?
    /// Light foreground heartbeat so the Mac sees fresh "last seen" / online
    /// status (iOS auto-pauses timers when the app is suspended, so this is
    /// effectively foreground-only — no background battery cost).
    private let heartbeatInterval: TimeInterval = 30

    private init() {}

    /// Start publishing presence. Event-driven (no 60s wire timer): the first
    /// heartbeat fires when the private engine's zone becomes ready; subsequent
    /// ones fire on app activation and after connection changes.
    func start() {
        if CompanionSyncEngine.shared.zoneReady {
            publish()
        } else {
            CompanionSyncEngine.shared.onZoneReady = { [weak self] in
                self?.publish()
            }
        }
        // Foreground heartbeat for live presence on the Mac side.
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    /// Force-publish right now (used on app foreground, after a connection
    /// change, etc.). Debounced to one publish per 10s unless forced.
    func publishNow(force: Bool = false) {
        if force || Date().timeIntervalSince(lastPublishedAt) > 10 {
            publish()
        }
    }

    /// Build + enqueue the iPhone's DeviceRecord into every paired Mac's zone.
    /// A same-iCloud Mac shares its private zone (zoneOwner = current user);
    /// a different-iCloud Mac is reached through its shared zone (zoneOwner =
    /// the Mac owner's record name).
    private func publish() {
        // Same-iCloud discovery + presence: ALWAYS write our DeviceRecord into
        // the private DoomCoderZone once it's ready. Same-Apple-ID devices share
        // one private database, so this single record is how the Mac DISCOVERS
        // this iPhone for the very first pairing (its picker is fed by the
        // DeviceRecords it fetches) AND how it keeps "last seen" fresh after.
        // It does not require an existing connection — that was the chicken-and-
        // egg bug (no connection → no record → nothing to discover → no pairing).
        var didPublish = false
        if CompanionSyncEngine.shared.zoneReady {
            enqueuePrivate()
            didPublish = true
        }

        // Cross-account presence: write into each accepted different-iCloud
        // Mac's SHARED zone. This genuinely needs an accepted CKShare, so it is
        // gated on an active ckShare connection (there is no pre-pairing
        // discovery channel for different Apple IDs — that's what QR/code is for).
        for conn in ConnectionStore.shared.connections where conn.status == .active {
            if case .ckShare(let ref) = conn.route, !ref.isSameAccount, !ref.ownerRecordName.isEmpty {
                enqueueShared(zoneOwner: ref.ownerRecordName)
                didPublish = true
            }
        }
        if didPublish { lastPublishedAt = Date() }
    }

    // MARK: - Private-DB path (same iCloud)

    private func enqueuePrivate() {
        let engine = CompanionSyncEngine.shared
        guard engine.zoneReady, let engineRef = engine.internalSyncEngine else { return }
        let rec = buildRecord()
        let recordID = rec.recordID  // zoneOwner = CKCurrentUserDefaultName
        DeviceRecordPublisherCache.shared.put(rec, recordID: recordID)
        engineRef.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        SyncTelemetry.shared.record(.stateUpdate, side: .ios, detail: "device heartbeat (private)")
    }

    // MARK: - Shared-DB path (different iCloud)

    private func enqueueShared(zoneOwner: String) {
        guard let engineRef = SharedDatabaseSync.shared.internalEngine else {
            // Engine not ready yet — kick a setup; the next heartbeat lands.
            SharedDatabaseSync.shared.start()
            return
        }
        let rec = buildRecord()
        let recordID = rec.recordID(zoneOwner: zoneOwner)
        DeviceRecordPublisherCache.shared.put(rec, recordID: recordID, zoneOwner: zoneOwner)
        engineRef.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        SyncTelemetry.shared.record(.stateUpdate, side: .ios, detail: "device heartbeat (shared)")
    }

    // MARK: - Disconnect

    /// Enqueue a deletion of this iPhone's OWN DeviceRecord from a Mac's zone.
    /// Called when the user disconnects a Mac so the Mac drops the iPhone card.
    func enqueueDeletion(for connection: Connection) {
        let iosId = IosDeviceId.current
        switch connection.route {
        case .ckShare(let ref) where !ref.isSameAccount && !ref.ownerRecordName.isEmpty:
            guard let engineRef = SharedDatabaseSync.shared.internalEngine else { return }
            let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: ref.ownerRecordName)
            let recordID = CKRecord.ID(recordName: "Device-\(iosId)", zoneID: zone)
            DeviceRecordPublisherCache.shared.forget(recordID: recordID)
            engineRef.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        default:
            guard let engineRef = CompanionSyncEngine.shared.internalSyncEngine else { return }
            let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
            let recordID = CKRecord.ID(recordName: "Device-\(iosId)", zoneID: zone)
            DeviceRecordPublisherCache.shared.forget(recordID: recordID)
            engineRef.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        }
    }

    // MARK: - Record construction

    private func buildRecord() -> DeviceRecord {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let battery: Double? = (level >= 0) ? Double(level) : nil

        // Best-effort iCloud account identity from a paired connection (captured
        // at share-accept time). Carried so the Mac can label the iPhone card.
        let conn = ConnectionStore.shared.connections.first { $0.status == .active }
        return DeviceRecord(
            deviceId: IosDeviceId.current,
            role: .ios,
            displayName: IosDeviceId.displayName,
            model: IosDeviceId.model,
            osVersion: IosDeviceId.systemName,
            appVersion: IosDeviceId.appVersion,
            lastSeen: Date(),
            accountName: conn?.peerAccountName,
            accountEmail: conn?.peerAccountEmail,
            battery: battery
        )
    }
}

// MARK: - DeviceRecord publisher cache (shared by both engine batch delegates)

/// Holds the most recently built `DeviceRecord(role: .ios)` per recordID so
/// either engine's `nextRecordZoneChangeBatch` can materialise the CKRecord on
/// demand. Persists the server `recordChangeTag` (system fields) so heartbeats
/// after relaunch are clean UPDATEs, not blind INSERTs (which 14/2004 forever).
@MainActor
final class DeviceRecordPublisherCache {
    static let shared = DeviceRecordPublisherCache()
    private init() {}

    /// Pending DeviceRecord + its zoneOwner (nil = private/current-user zone).
    private var pending: [String: (record: DeviceRecord, zoneOwner: String?)] = [:]

    private let serverCache = ServerRecordCache(
        defaults: AppGroupCache.defaults,
        key: "ck.ios.deviceRecord.serverCache.v7"
    )

    func put(_ r: DeviceRecord, recordID: CKRecord.ID, zoneOwner: String? = nil) {
        pending[recordID.recordName + "@" + recordID.zoneID.ownerName] = (r, zoneOwner)
    }

    private func key(_ recordID: CKRecord.ID) -> String {
        recordID.recordName + "@" + recordID.zoneID.ownerName
    }

    func buildCKRecord(for recordID: CKRecord.ID) -> CKRecord? {
        guard let entry = pending[key(recordID)] else { return nil }
        let base = serverCache.record(for: recordID)
        let built: CKRecord
        if let owner = entry.zoneOwner {
            built = entry.record.toCKRecord(zoneOwner: owner, base: base)
        } else {
            built = entry.record.toCKRecord(base: base)
        }
        if let base, base !== built {
            for k in built.allKeys() { base[k] = built[k] }
            return base
        }
        return built
    }

    func didSave(_ record: CKRecord) {
        serverCache.store(record)
        pending.removeValue(forKey: key(record.recordID))
    }

    /// Stash the server's copy after a `serverRecordChanged` failure WITHOUT
    /// clearing pending, so the next batch rebuilds against the fresh etag.
    func noteServerRecord(_ record: CKRecord) {
        serverCache.store(record)
    }

    /// Drop a stale etag (record deleted server-side / `unknownItem`).
    func forgetServerRecord(_ recordID: CKRecord.ID) {
        serverCache.remove(name: recordID.recordName)
    }

    func forget(recordID: CKRecord.ID) {
        pending.removeValue(forKey: key(recordID))
        serverCache.remove(name: recordID.recordName)
    }

    func clear() {
        pending.removeAll()
        serverCache.clear()
    }
}
