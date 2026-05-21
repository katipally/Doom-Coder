// CompanionSyncEngine.swift — DoomCoder Companion
// The central CloudKit sync coordinator for the iOS companion app.
// Uses CKSyncEngine (iOS 17+) for efficient, delta-based synchronisation of
// the DoomCoderZone. Decodes incoming records and fans them out to the
// appropriate Observable stores.

import Foundation
import CloudKit
import DoomCoderCore

@MainActor
@Observable
final class CompanionSyncEngine: NSObject {

    // MARK: - Singleton

    static let shared = CompanionSyncEngine()
    private override init() {}

    // MARK: - Public state

    var accountAvailable: Bool = false
    var lastSyncAt: Date?
    var zoneReady: Bool = false
    /// Flips true the first time `.fetchedRecordZoneChanges` resolves
    /// (regardless of result count) so the UI can distinguish "first fetch
    /// is in flight" from "fetch completed but no Mac has paired yet".
    var firstFetchCompleted: Bool = false

    // MARK: - Private CloudKit plumbing

    private let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
    private var db: CKDatabase { container.privateCloudDatabase }
    private var zone: CKRecordZone { CKRecordZone(zoneName: CloudKitConstants.zoneName) }

    private var syncEngine: CKSyncEngine?

    /// Prevents subscriptions from being registered more than once per launch.
    private var subscriptionsReady = false

    /// Records queued for the next CKSyncEngine push batch, keyed by recordID
    /// so a rapid second edit to the same record overwrites the first instead
    /// of producing two `.saveRecord(sameID)` entries (which CloudKit rejects
    /// as "You can't save the same record twice").
    private var recordsByID: [CKRecord.ID: CKRecord] = [:]

    // MARK: - Defaults key for engine state

    private static let engineStateKey = "ck.engineState"
    private var sharedDefaults: UserDefaults { AppGroupCache.defaults }

    // MARK: - Lifecycle

    func start() {
        Task { await setupSyncEngine() }
    }

    private func setupSyncEngine() async {
        // Verify account status first.
        do {
            let status = try await container.accountStatus()
            accountAvailable = (status == .available)
        } catch {
            accountAvailable = false
            print("[CompanionSyncEngine] accountStatus error: \(error)")
        }

        guard accountAvailable else { return }

        // Restore persisted engine state so CKSyncEngine can resume correctly.
        let serialization: CKSyncEngine.State.Serialization? = {
            guard let data = sharedDefaults.data(forKey: Self.engineStateKey),
                  let s = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            else { return nil }
            return s
        }()

        let config = CKSyncEngine.Configuration(
            database: db,
            stateSerialization: serialization,
            delegate: self
        )

        syncEngine = CKSyncEngine(config)

        // Register subscriptions once per launch after the engine is up.
        if !subscriptionsReady {
            subscriptionsReady = true
            await ensureSubscriptions()
        }
    }

    // MARK: - Public API

    func fetchChanges() async {
        guard let engine = syncEngine else { return }
        try? await engine.fetchChanges()
    }

    func handleRemoteNotification() async {
        await fetchChanges()
    }

    private func ensureSubscriptions() async {
        await setupDatabaseSubscription()
        await setupNotificationLogSubscription()
        await setupMacStatusSubscription()
        await setupSessionSubscription()
    }

    /// Enqueue a CKRecord for the next outbound sync batch.
    /// Latest write per recordID wins (overwrites in-flight queued copy).
    func enqueueSave(_ record: CKRecord) {
        recordsByID[record.recordID] = record
        syncEngine?.state.add(pendingRecordZoneChanges: [
            CKSyncEngine.PendingRecordZoneChange.saveRecord(record.recordID)
        ])
    }

    // MARK: - Subscriptions

    private func setupDatabaseSubscription() async {
        let sub = CKDatabaseSubscription(subscriptionID: "companion-db-sub")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendMutableContent = true
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do {
            try await db.save(sub)
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            // Already exists — that is fine.
        } catch {
            print("[CompanionSyncEngine] DB subscription error: \(error)")
        }
    }

    private func setupNotificationLogSubscription() async {
        // Delete all previous subscription versions.
        for id in ["companion-notiflog-sub", "companion-notiflog-sub-v2",
                   "companion-notiflog-sub-v3", "companion-notiflog-sub-v4",
                   "companion-notiflog-sub-v5", "companion-notiflog-sub-v6",
                   "companion-notiflog-sub-v7"] {
            _ = try? await db.deleteSubscription(withID: id)
        }

        let yesterday = Date(timeIntervalSinceNow: -86_400)
        let pred = NSPredicate(format: "ts > %@", yesterday as NSDate)
        let sub = CKQuerySubscription(
            recordType: CloudKitConstants.RecordType.notificationLog,
            predicate: pred,
            subscriptionID: "companion-notiflog-sub-v8",
            options: .firesOnRecordCreation
        )
        let info = CKSubscription.NotificationInfo()
        // Use title/body localization-key substitution so APNs delivers the
        // Mac-rendered title and body in `aps.alert.title` / `aps.alert.body`
        // *directly*. The OS displays the right text even if the NSE never
        // runs (low-power / killed extension / decode failure). NSE then only
        // adds icon attachment, thread identifier, and interruption level.
        //
        // "%@" with a single CKRecord field name in the args array tells
        // CloudKit to substitute that field's string value verbatim. This is
        // the canonical way to wire query subscriptions to real push content.
        info.titleLocalizationKey  = "%@"
        info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey  = "%@"
        info.alertLocalizationArgs = ["body"]
        info.shouldSendMutableContent = true   // invokes NSE on each push
        info.soundName = "default"
        // v8 desiredKeys (CloudKit hard limit: 5):
        //   title      → aps.alert.title via titleLocalizationArgs (also NSE fallback)
        //   body       → aps.alert.body  via alertLocalizationArgs (also NSE fallback)
        //   agent      → icon slug + interruption level
        //   phase      → interruption level
        //   sessionKey → UNNotification threadIdentifier
        info.desiredKeys = ["title", "body", "agent", "phase", "sessionKey"]
        sub.notificationInfo = info
        sub.zoneID = zone.zoneID
        do {
            try await db.save(sub)
            print("[CompanionSyncEngine] notiflog sub v8 registered")
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            print("[CompanionSyncEngine] notiflog sub v8 already exists")
        } catch {
            print("[CompanionSyncEngine] NotifLog subscription error: \(error)")
        }
    }

    private func setupMacStatusSubscription() async {
        let sub = CKQuerySubscription(
            recordType: CloudKitConstants.RecordType.macStatus,
            predicate: NSPredicate(value: true),
            subscriptionID: "companion-macstatus-sub-v1",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        sub.zoneID = zone.zoneID
        do {
            try await db.save(sub)
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            // Already exists.
        } catch {
            print("[CompanionSyncEngine] MacStatus subscription error: \(error)")
        }
    }

    private func setupSessionSubscription() async {
        let sub = CKQuerySubscription(
            recordType: CloudKitConstants.RecordType.session,
            predicate: NSPredicate(value: true),
            subscriptionID: "companion-session-sub-v1",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        sub.zoneID = zone.zoneID
        do {
            try await db.save(sub)
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            // Already exists.
        } catch {
            print("[CompanionSyncEngine] Session subscription error: \(error)")
        }
    }

    // MARK: - Record fan-out

    nonisolated private func handleFetched(_ record: CKRecord) {
        // Use Task.detached to stay outside the CKSyncEngine delegate task tree.
        // An inherited Task here would still be a child of the delegate callback,
        // which can cause reentrancy crashes if any store mutation triggers
        // additional CKSyncEngine operations.
        Task.detached { @MainActor in
            switch record.recordType {
            case CloudKitConstants.RecordType.macStatus:
                if let r = MacStatusRecord(record) { MacStatusStore.shared.upsert(r) }
            case CloudKitConstants.RecordType.session:
                if let r = SessionRecord(record) { SessionStore.shared.upsert(r) }
            case CloudKitConstants.RecordType.notificationLog:
                if let r = NotificationLogRecord(record) { NotificationLogStore.shared.append(r) }
            case CloudKitConstants.RecordType.settings:
                if let r = SettingsRecord(record) { SettingsStore.shared.applyRemote(r, rawRecord: record) }
            case CloudKitConstants.RecordType.wolProfile:
                // v3.0 retired Wake-on-LAN; ignore stragglers from older Macs.
                break
            case CloudKitConstants.RecordType.agentIcon:
                if let r = AgentIconRecord(record), let asset = r.pngAsset,
                   let fileURL = asset.fileURL,
                   let data = try? Data(contentsOf: fileURL) {
                    let slug = TrackedAgent(rawValue: r.agent)?.iconSlug ?? r.agent
                    AppGroupCache.writeIcon(slug: slug, data: data)
                }
            case CloudKitConstants.RecordType.controlCommand:
                // Mac stamps appliedAt + result after processing the command.
                // Route the updated record to CommandPublisher so the stream
                // completes with the real Mac acknowledgement.
                if let r = ControlCommandRecord(record) { CommandPublisher.shared.handleEcho(r) }
            default:
                break
            }
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension CompanionSyncEngine: CKSyncEngineDelegate {

    nonisolated func handleEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {
        switch event {
        case .stateUpdate(let e):
            // Persist the engine state so we can restore across launches.
            if let data = try? JSONEncoder().encode(e.stateSerialization) {
                await MainActor.run {
                    AppGroupCache.defaults.set(data, forKey: Self.engineStateKey)
                    self.lastSyncAt = Date()
                }
            }

        case .accountChange(let e):
            await MainActor.run {
                switch e.changeType {
                case .signIn:
                    self.accountAvailable = true
                case .signOut:
                    self.accountAvailable = false
                    self.recordsByID.removeAll()
                case .switchAccounts:
                    MacStatusStore.shared.clear()
                    SessionStore.shared.clear()
                    SettingsStore.shared.clear()
                    NotificationLogStore.shared.entries.removeAll()
                    self.recordsByID.removeAll()
                    self.accountAvailable = true
                @unknown default:
                    break
                }
            }

        case .fetchedRecordZoneChanges(let e):
            for change in e.modifications {
                await MainActor.run {
                    self.handleFetched(change.record)
                }
            }
            await MainActor.run {
                self.zoneReady = true
                self.firstFetchCompleted = true
                self.lastSyncAt = Date()
            }

        case .willSendChanges:
            break

        case .sentRecordZoneChanges(let e):
            // Drop successfully-saved records from our local queue map.
            if !e.savedRecords.isEmpty {
                let savedIDs = e.savedRecords.map(\.recordID)
                await MainActor.run {
                    for id in savedIDs { self.recordsByID.removeValue(forKey: id) }
                }
            }
            for save in e.savedRecords {
                if save.recordType == CloudKitConstants.RecordType.controlCommand,
                   let cmd = ControlCommandRecord(save) {
                    await MainActor.run {
                        CommandPublisher.shared.handleEcho(cmd)
                    }
                }
            }
            // When a record fails with .serverRecordChanged, the server already
            // has a newer copy. Re-fetch so our local state catches up.
            // Do NOT re-enqueue a save — iOS is a read-mostly client for Settings.
            if !e.failedRecordSaves.isEmpty {
                for fail in e.failedRecordSaves {
                    print("[CompanionSyncEngine] save conflict on \(fail.record.recordID.recordName): \(fail.error.localizedDescription)")
                    let recordID = fail.record.recordID
                    // If Settings-singleton conflicts, clear our cached server record
                    // so the next user edit doesn't re-use a stale changeTag.
                    if recordID.recordName == SettingsRecord.singletonRecordName {
                        await MainActor.run { SettingsStore.shared.serverRecord = nil }
                    }
                    // Drop the failed record from our queue. CKSyncEngine
                    // already removed the pending change from its state for
                    // non-retryable errors; for retryable ones it keeps the
                    // pending change and will call us again — at which point
                    // recordProvider will return nil for this ID and the
                    // engine will skip it. Either way, holding onto the stale
                    // record only invites the duplicate-save bug.
                    await MainActor.run {
                        self.recordsByID.removeValue(forKey: recordID)
                    }
                }
                // MUST use Task.detached — calling engine.fetchChanges() from
                // inside a delegate callback causes a CKSyncEngine reentrancy
                // crash (Task 840: "BUG IN CLIENT OF CLOUDKIT"). Detached task
                // runs outside the delegate's task tree, satisfying CKSyncEngine's
                // serial-delegate guarantee.
                Task.detached { [weak self] in await self?.fetchChanges() }
            }

        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Canonical pattern: use the engine's deduped pending-change list
        // (filtered by send scope) and serve records from our local map.
        // The engine guarantees each recordID appears at most once here, so
        // the resulting batch can never contain duplicate save entries.
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        let snapshot: [CKRecord.ID: CKRecord] = await MainActor.run { self.recordsByID }
        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: changes,
            recordProvider: { id in snapshot[id] }
        )
    }
}
