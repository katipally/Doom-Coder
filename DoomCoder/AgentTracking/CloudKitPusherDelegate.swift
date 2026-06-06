// CloudKitPusherDelegate.swift
//
// CKSyncEngineDelegate for the Mac push-only pipeline.

import Foundation
import CloudKit
import OSLog
import Observation
import DoomCoderCore

final class CloudKitPusherDelegate: NSObject, CKSyncEngineDelegate, @unchecked Sendable {

    private let logger = Logger(subsystem: "com.doomcoder", category: "ckpusher.delegate")
    private weak var pusher: CloudKitPusher?
    private let stateKey: String

    init(pusher: CloudKitPusher, stateKey: String) {
        self.pusher = pusher
        self.stateKey = stateKey
    }

    // MARK: - Engine events

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let upd):
            await persistState(upd.stateSerialization)

        case .accountChange(let change):
            // Lesson #3 — wipe local server-record cache and let
            // CloudKitPusher.setupSyncEngine rebuild.
            await MainActor.run {
                self.pusher?.serverRecords.clear()
                NotificationCenter.default.post(name: .cloudKitPusherReady, object: nil)
            }
            logger.notice("ckpusher.delegate: accountChange \(String(describing: change.changeType), privacy: .public)")

        case .sentRecordZoneChanges(let sent):
            for saved in sent.savedRecords {
                let name = saved.recordID.recordName
                await MainActor.run {
                    // Lesson #1 — persist server-known CKRecord for singletons
                    // (the Mac's own Device record, AgentConfig, AgentIcon).
                    self.pusher?.serverRecords.store(saved)
                    self.pusher?.clearPending(for: saved.recordID)
                    self.pusher?.resolveSend(name: name, success: true)
                }
            }
            for failed in sent.failedRecordSaves {
                let code = failed.error.code
                let name = failed.record.recordID.recordName
                logger.error("ckpusher.delegate: failed save \(name, privacy: .public) code=\(String(describing: code), privacy: .public)")
                await MainActor.run {
                    self.pusher?.resolveSend(name: name, success: false)
                }
                // Singletons (the Mac's own Device record, AgentConfig, …):
                // stash the server
                // etag and re-enqueue so the next batch rebuilds as an UPDATE
                // (Apple requires resolving serverRecordChanged ourselves).
                await MainActor.run {
                    if let serverRec = failed.error.serverRecord {
                        self.pusher?.serverRecords.store(serverRec)
                    }
                }
                if code == .serverRecordChanged || code == .unknownItem {
                    if code == .unknownItem {
                        await MainActor.run {
                            self.pusher?.serverRecords.remove(id: failed.record.recordID)
                        }
                    }
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                }
            }

        case .sentDatabaseChanges:
            break

        case .fetchedRecordZoneChanges(let fetched):
            // Persist the server record cache for every modification so the
            // next save has a valid change tag (CKError 14/2004 prevention).
            for mod in fetched.modifications {
                let record = mod.record
                await MainActor.run { self.pusher?.serverRecords.store(record) }
            }
            // v7: peer iOS DeviceRecords (one presence/profile record per
            // device) update the unified store + the Connections tab. Routed
            // UNCONDITIONALLY into the store so the Mac always knows the real
            // iPhone identity even before a Connection matches.
            for mod in fetched.modifications {
                guard mod.record.recordType == CloudKitConstants.RecordType.device else { continue }
                await MainActor.run { self.pusher?.ingestDeviceRecord(mod.record) }
            }
            // v7: a deleted peer DeviceRecord (iPhone disconnected from its
            // side, or the shared zone was revoked) drops the Connection +
            // store entry so the Mac list updates.
            for deletion in fetched.deletions {
                let name = deletion.recordID.recordName
                await MainActor.run { self.pusher?.handleDeviceRecordDeletion(recordName: name) }
            }
            // v2.8: when a CKShare record changes (e.g. the iPhone just
            // accepted), notify the pairing coordinator so the QR sheet
            // dismisses immediately. The coordinator does its own
            // post-acceptance bookkeeping (creates the Connection).
            // This replaces the previous 3-second polling loop with
            // an APNs-driven signal.
            for mod in fetched.modifications {
                if mod.record is CKShare {
                    NotificationCenter.default.post(name: .doomCoderShareAccepted, object: nil)
                }
            }
            // A successful fetch proves the Mac is reaching CloudKit right now,
            // so re-stamp lastSeen (debounced) to keep the iOS reachability
            // banner honest even when no commands were pending.
            await MainActor.run { self.pusher?.touchLastSeen() }

        case .willSendChanges, .didSendChanges,
             .willFetchChanges, .didFetchChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .fetchedDatabaseChanges:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Batches

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            // v7: materialize only the Mac's own records (its own Device record
            // + the Mac singletons + pending deletes). buildRecord guards that a
            // peer's Device-<iosId> never resolves to a record here.
            await MainActor.run {
                self.pusher?.buildRecord(for: recordID)
            }
        }
    }

    // MARK: - State persistence

    @MainActor
    private func persistState(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }
}
