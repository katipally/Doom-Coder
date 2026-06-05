// ShareSubscription.swift — DoomCoder Companion
// Per-share CKSyncEngine delegate. The delegate is intentionally minimal in
// v2.7: it persists engine state to UserDefaults and routes fetch results
// into the same stores that the base CompanionSyncEngine uses. The
// existing CompanionSyncEngine's record-handling code is shared.

import Foundation
import CloudKit
import OSLog
import DoomCoderCore

final class ShareSubscription: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    let connection: Connection
    let shareURL: URL?
    let stateKey: String
    private let logger = Logger(subsystem: "com.doomcoder", category: "sharesync")

    init(connection: Connection, shareURL: URL?, stateKey: String) {
        self.connection = connection
        self.shareURL = shareURL
        self.stateKey = stateKey
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let stateUpdate):
            if let serialized = try? JSONEncoder().encode(stateUpdate.stateSerialization) {
                UserDefaults.standard.set(serialized, forKey: stateKey)
            }
        case .accountChange:
            // No-op in v2.7; user can re-pair if needed.
            break
        case .fetchedDatabaseChanges(let event):
            // When the Mac revokes the CKShare, the zone disappears from
            // the participant's sharedCloudDatabase. Auto-remove the local
            // connection so the iOS UI stays consistent.
            let revokedZoneNames = Set(event.deletions.map { $0.zoneID.zoneName })
            if revokedZoneNames.contains(CloudKitConstants.zoneName) {
                await MainActor.run { [self] in
                    ConnectionStore.shared.remove(id: connection.id)
                    ShareSyncEngineRegistry.shared.unregister(connectionId: connection.id)
                }
            }
        case .fetchedRecordZoneChanges(let event):
            await CompanionSyncEngine.shared.handleFetchedZoneChanges(event, from: connection)
        case .sentDatabaseChanges:
            break
        case .sentRecordZoneChanges:
            break
        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await MainActor.run {
                if recordID.recordName.hasPrefix("CSC-") {
                    return CSCPendingCache.shared.buildCKRecord(for: recordID)
                }
                return nil
            }
        }
    }
}
