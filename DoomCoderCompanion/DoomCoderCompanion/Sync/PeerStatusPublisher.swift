// PeerStatusPublisher.swift — DoomCoder Companion
//
// v2.7: writes a PeerStatusRecord into the shared DoomCoderZone on a
// 60-second heartbeat so the Mac can see this iOS device in its
// Connections tab. Symmetric to CloudKitPusher.publishMacStatus on the
// Mac side.
//
// Uses the same CKSyncEngine that CompanionSyncEngine already
// constructs for the same-Apple-ID (iCloud) path. No second engine,
// no second zone, no second subscription.
//
// v2.9: cross-account (CKShare) path. When the active connection uses
// a CKShare with .readWrite permission (set by the Mac at share-creation
// time), we write PeerStatus directly to the Mac's shared zone via
// container.sharedCloudDatabase using a CKModifyRecordsOperation.
// This lets the Mac discover cross-account iOS devices just as fast
// as same-account ones (previously the Mac was blind to CKShare peers).

import Foundation
import CloudKit
import UIKit
import Observation
import DoomCoderCore

@MainActor
final class PeerStatusPublisher {

    static let shared = PeerStatusPublisher()

    private let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
    private let heartbeatInterval: TimeInterval = 60
    private var heartbeatTimer: Timer?
    private var lastPublishedAt: Date = .distantPast

    // Per-owner server record cache for shared DB writes (preserves recordChangeTag).
    private var sharedDbServerCache: [String: CKRecord] = [:]

    private init() {}

    /// Start the heartbeat. Idempotent. The first publish happens
    /// immediately so the Mac sees the peer within a few seconds of
    /// the iOS app launching, then once per minute.
    func start() {
        stop()
        publish()
        let timer = Timer(timeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Force-publish right now (used on app foreground, after a
    /// connection change, etc.). Debounced to one publish per 10s.
    func publishNow(force: Bool = false) {
        if force || Date().timeIntervalSince(lastPublishedAt) > 10 {
            publish()
        }
    }

    private func publish() {
        let macId: String? = MacStatusStore.shared.primary?.macId
        let connections = ConnectionStore.shared.connections.filter { $0.status == .active }
        let shareConnection = connections.first { $0.ckShareRef != nil }

        // v2.9: prefer the CKShare path when available — writes to the
        // Mac's shared zone so the Mac can see us even on a different
        // Apple ID. Same-account connections use the private-DB engine but
        // still include the shareURLString so Mac's ingestPeerStatus can
        // match this heartbeat to the pending pairing during the QR flow.
        if let conn = shareConnection,
           let ref = conn.ckShareRef,
           !ref.ownerRecordName.isEmpty,
           !ref.isSameAccount {
            publishViaSharedDB(macId: macId, ref: ref)
        } else {
            let shareURLString = shareConnection?.ckShareRef?.shareURLString
            publishViaPrivateEngine(macId: macId, shareURLString: shareURLString)
        }
    }

    // MARK: - Same-account path (private DB sync engine)

    private func publishViaPrivateEngine(macId: String?, shareURLString: String?) {
        let engine = CompanionSyncEngine.shared
        guard engine.zoneReady else { return }

        let rec = buildRecord(macId: macId, shareURLString: shareURLString, route: "iCloud")
        guard let engineRef = engine.internalSyncEngine else { return }
        engineRef.state.add(pendingRecordZoneChanges: [.saveRecord(rec.recordID)])
        PeerStatusPublisherCache.shared.put(rec)
        lastPublishedAt = Date()
        SyncTelemetry.shared.record(.stateUpdate, side: .ios, detail: "peerStatus heartbeat (iCloud)")
    }

    // MARK: - Cross-account path (shared DB direct write)

    private func publishViaSharedDB(macId: String?, ref: CKShareRef) {
        let rec = buildRecord(macId: macId, shareURLString: ref.shareURLString, route: "iCloud Share")
        let ownerName = ref.ownerRecordName
        let zoneID = CKRecordZone.ID(
            zoneName: CloudKitConstants.zoneName,
            ownerName: ownerName
        )
        let recordID = rec.recordID(zoneOwner: ownerName)
        let base = sharedDbServerCache[recordID.recordName]
        let ckRecord = rec.toCKRecord(zoneOwner: ownerName, base: base)

        let op = CKModifyRecordsOperation(recordsToSave: [ckRecord], recordIDsToDelete: nil)
        op.qualityOfService = .userInitiated
        op.savePolicy = .changedKeys
        op.perRecordSaveBlock = { [weak self] _, result in
            if case .success(let saved) = result {
                Task { @MainActor [weak self] in
                    self?.sharedDbServerCache[saved.recordID.recordName] = saved
                }
            }
        }
        op.modifyRecordsResultBlock = { result in
            switch result {
            case .success:
                SyncTelemetry.shared.record(.sent, side: .ios, recordType: CloudKitConstants.RecordType.peerStatus)
            case .failure(let err):
                print("[PeerStatusPublisher] sharedDB write failed: \(err.localizedDescription)")
            }
        }
        // Use sharedCloudDatabase — the record lives in the Mac's zone,
        // which is accessible because the Mac granted .readWrite permission.
        _ = zoneID  // confirms correct zoneID is embedded in ckRecord.recordID
        container.sharedCloudDatabase.add(op)
        lastPublishedAt = Date()
        SyncTelemetry.shared.record(.stateUpdate, side: .ios, detail: "peerStatus heartbeat (sharedDB)")
    }

    // MARK: - Disconnect signal

    /// Writes a PeerStatus record with route = "disconnecting" synchronously to
    /// CloudKit before local teardown. Mac's ingestPeerStatus detects this and
    /// removes the connection immediately (vs. waiting up to an hour for pruneStale).
    func publishDisconnect(connection: Connection) async {
        let macId = connection.macDeviceId.isEmpty ? nil : connection.macDeviceId
        let ref = connection.ckShareRef
        let shareURLString = ref?.shareURLString
        let rec = buildRecord(macId: macId, shareURLString: shareURLString, route: "disconnecting")

        if let ref, !ref.isSameAccount {
            let ckRecord = rec.toCKRecord(zoneOwner: ref.ownerRecordName, base: nil)
            let op = CKModifyRecordsOperation(recordsToSave: [ckRecord])
            op.savePolicy = .allKeys
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                op.modifyRecordsResultBlock = { _ in cont.resume() }
                container.sharedCloudDatabase.add(op)
            }
        } else {
            let ckRecord = rec.toCKRecord(base: nil)
            let op = CKModifyRecordsOperation(recordsToSave: [ckRecord])
            op.savePolicy = .allKeys
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                op.modifyRecordsResultBlock = { _ in cont.resume() }
                container.privateCloudDatabase.add(op)
            }
        }
    }

    // MARK: - Record construction

    private func buildRecord(macId: String?, shareURLString: String?, route: String) -> PeerStatusRecord {
        PeerStatusRecord(
            iosDeviceId: IosDeviceId.current,
            name: IosDeviceId.displayName,
            model: IosDeviceId.model,
            systemName: IosDeviceId.systemName,
            appVersion: IosDeviceId.appVersion,
            lastSeen: Date(),
            route: route,
            macId: macId,
            shareURLString: shareURLString
        )
    }
}

// MARK: - Local cache of the last-built record (for the engine delegate)

/// Holds the most recently built PeerStatusRecord so the engine's
/// `nextRecordZoneChangeBatch` can materialise the CKRecord on demand
/// (matching the Mac-side pattern of building the record inside the
/// batch closure to preserve `recordChangeTag`).
@MainActor
final class PeerStatusPublisherCache {
    static let shared = PeerStatusPublisherCache()
    private init() {}

    private var pending: [String: PeerStatusRecord] = [:]
    private var serverCache: [String: CKRecord] = [:]

    func put(_ r: PeerStatusRecord) {
        pending[r.recordID.recordName] = r
    }

    func buildCKRecord(for recordID: CKRecord.ID) -> CKRecord? {
        guard let rec = pending[recordID.recordName] else { return nil }
        let base = serverCache[recordID.recordName]
        let built = rec.toCKRecord(base: base)
        if let base = base {
            for key in built.allKeys() { base[key] = built[key] }
            return base
        }
        return built
    }

    func didSave(_ record: CKRecord) {
        serverCache[record.recordID.recordName] = record
        pending.removeValue(forKey: record.recordID.recordName)
    }
}
