// SharedDatabaseSync.swift — DoomCoder Companion
//
// v6: exactly ONE CKSyncEngine for the entire shared CloudKit database.
//
// This replaces the old `ShareSyncEngineRegistry` + `ShareSubscription`
// pair, which spun up one CKSyncEngine PER accepted CKShare on the same
// `sharedCloudDatabase`. Apple's guidance is one engine per database —
// multiple engines on a single database "trip over each other" and drop
// sync events. With a single shared-DB engine + a database subscription,
// CloudKit delivers every participant zone's changes through one delegate.
//
// This engine is READ-ONLY: it fetches records from every shared zone the
// iPhone participates in (the Mac's zones for cross-account pairings) and
// fans them through the same `CompanionSyncEngine.ingestSharedRecord` path
// as the private engine, and it detects share revocation (a shared zone
// disappearing) to hard-remove the matching local Connection. Outbound
// cross-account writes (PeerStatus / CSC into the Mac's shared zone) are
// done as direct idempotent `CKModifyRecordsOperation`s elsewhere — those
// are not engines, so they don't conflict with this single read engine.

import Foundation
import CloudKit
import OSLog
import DoomCoderCore

@MainActor
final class SharedDatabaseSync {

    static let shared = SharedDatabaseSync()

    private let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
    private var db: CKDatabase { container.sharedCloudDatabase }
    private let stateKey = "ck.sharedEngineState.v6"
    private let logger = Logger(subsystem: "com.doomcoder", category: "sharedsync")

    private var engine: CKSyncEngine?
    private var delegate: SharedDatabaseSyncDelegate?
    private var setupInProgress = false
    private var subscriptionReady = false

    private init() {}

    var isReady: Bool { engine != nil }

    /// Construct the single shared-DB engine. Idempotent + re-entrancy guarded.
    func start() {
        Task { await setup() }
    }

    func setup() async {
        guard !setupInProgress else { return }
        setupInProgress = true
        defer { setupInProgress = false }

        let serialization: CKSyncEngine.State.Serialization? = {
            guard let data = AppGroupCache.defaults.data(forKey: stateKey),
                  let s = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            else { return nil }
            return s
        }()

        let del = SharedDatabaseSyncDelegate(stateKey: stateKey)
        delegate = del
        var config = CKSyncEngine.Configuration(
            database: db,
            stateSerialization: serialization,
            delegate: del
        )
        config.automaticallySync = true
        let e = CKSyncEngine(config)
        engine = e

        if !subscriptionReady {
            subscriptionReady = true
            await ensureSubscription()
        }

        do {
            try await e.fetchChanges()
        } catch {
            logger.error("sharedsync: initial fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pull shared-zone changes now (event-driven: foreground / push / after
    /// a freshly-accepted CKShare).
    func fetchChanges() async {
        guard let engine else {
            await setup()
            return
        }
        do { try await engine.fetchChanges() }
        catch { logger.error("sharedsync: fetch failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func ensureSubscription() async {
        let sub = CKDatabaseSubscription(subscriptionID: "companion-shared-db-sub-v1")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do {
            try await db.save(sub)
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            // already exists
        } catch {
            logger.error("sharedsync: subscription error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Delegate

final class SharedDatabaseSyncDelegate: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    private let stateKey: String
    private let logger = Logger(subsystem: "com.doomcoder", category: "sharedsync.delegate")

    init(stateKey: String) {
        self.stateKey = stateKey
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let upd):
            if let data = try? JSONEncoder().encode(upd.stateSerialization) {
                await MainActor.run { AppGroupCache.defaults.set(data, forKey: stateKey) }
            }

        case .fetchedDatabaseChanges(let e):
            // A shared zone disappearing means the Mac revoked the share.
            let revoked = e.deletions.map { $0.zoneID }
            if !revoked.isEmpty {
                await MainActor.run {
                    for zoneID in revoked where zoneID.zoneName == CloudKitConstants.zoneName {
                        ConnectionStore.shared.removeCrossAccount(forZoneOwner: zoneID.ownerName)
                    }
                }
            }

        case .fetchedRecordZoneChanges(let e):
            for change in e.modifications {
                await MainActor.run { CompanionSyncEngine.shared.ingestSharedRecord(change.record) }
            }

        default:
            break
        }
    }

    // Read-only engine: no engine-managed writes, so never any pending batch.
    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        nil
    }
}
