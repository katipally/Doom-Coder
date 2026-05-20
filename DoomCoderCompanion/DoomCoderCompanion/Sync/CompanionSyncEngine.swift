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

    // MARK: - Private CloudKit plumbing

    private let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
    private var db: CKDatabase { container.privateCloudDatabase }
    private var zone: CKRecordZone { CKRecordZone(zoneName: CloudKitConstants.zoneName) }

    private var syncEngine: CKSyncEngine?

    /// Records queued for the next CKSyncEngine push batch.
    private var pendingSaves: [CKRecord] = []
    private var pendingDeletes: [CKRecord.ID] = []

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
    }

    // MARK: - Public API

    func fetchChanges() async {
        guard let engine = syncEngine else { return }
        try? await engine.fetchChanges()
    }

    func handleRemoteNotification() async {
        await fetchChanges()
    }

    func ensureSubscriptions() async {
        await setupDatabaseSubscription()
        await setupNotificationLogSubscription()
    }

    /// Enqueue a CKRecord for the next outbound sync batch.
    func enqueueSave(_ record: CKRecord) {
        pendingSaves.append(record)
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
        } catch let e as CKError where e.code == .serverRejectedRequest {
            // Already exists — that is fine.
        } catch {
            print("[CompanionSyncEngine] DB subscription error: \(error)")
        }
    }

    private func setupNotificationLogSubscription() async {
        let yesterday = Date(timeIntervalSinceNow: -86_400)
        let pred = NSPredicate(format: "ts > %@", yesterday as NSDate)
        let sub = CKQuerySubscription(
            recordType: CloudKitConstants.RecordType.notificationLog,
            predicate: pred,
            subscriptionID: "companion-notiflog-sub",
            options: .firesOnRecordCreation
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendMutableContent = true
        info.soundName = "default"
        info.desiredKeys = [
            "agent", "phase", "tool", "cwdBase", "sessionKey",
            "macName", "ts", "title", "body", "macId",
        ]
        sub.notificationInfo = info
        sub.zoneID = zone.zoneID
        do {
            try await db.save(sub)
        } catch let e as CKError where e.code == .serverRejectedRequest {
            // Already exists.
        } catch {
            print("[CompanionSyncEngine] NotifLog subscription error: \(error)")
        }
    }

    // MARK: - Record fan-out

    nonisolated private func handleFetched(_ record: CKRecord) {
        Task { @MainActor in
            switch record.recordType {
            case CloudKitConstants.RecordType.macStatus:
                if let r = MacStatusRecord(record) { MacStatusStore.shared.upsert(r) }
            case CloudKitConstants.RecordType.session:
                if let r = SessionRecord(record) { SessionStore.shared.upsert(r) }
            case CloudKitConstants.RecordType.notificationLog:
                if let r = NotificationLogRecord(record) { NotificationLogStore.shared.append(r) }
            case CloudKitConstants.RecordType.settings:
                if let r = SettingsRecord(record) { SettingsStore.shared.applyRemote(r) }
            case CloudKitConstants.RecordType.wolProfile:
                if let r = WoLProfileRecord(record) { WoLStore.shared.upsert(r) }
            case CloudKitConstants.RecordType.agentIcon:
                if let r = AgentIconRecord(record), let asset = r.pngAsset,
                   let fileURL = asset.fileURL,
                   let data = try? Data(contentsOf: fileURL) {
                    let slug = TrackedAgent(rawValue: r.agent)?.iconSlug ?? r.agent
                    AppGroupCache.writeIcon(slug: slug, data: data)
                }
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
                case .switchAccounts:
                    MacStatusStore.shared.clear()
                    SessionStore.shared.clear()
                    NotificationLogStore.shared.entries.removeAll()
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
                self.lastSyncAt = Date()
            }

        case .willSendChanges:
            break

        case .sentRecordZoneChanges(let e):
            for save in e.savedRecords {
                if save.recordType == CloudKitConstants.RecordType.controlCommand,
                   let cmd = ControlCommandRecord(save) {
                    await MainActor.run {
                        CommandPublisher.shared.handleEcho(cmd)
                    }
                }
            }

        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let saves: [CKRecord] = await MainActor.run {
            let batch = self.pendingSaves
            self.pendingSaves.removeAll()
            return batch
        }
        guard !saves.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: saves.map { .saveRecord($0.recordID) },
            recordProvider: { id in saves.first(where: { $0.recordID == id }) }
        )
    }
}
