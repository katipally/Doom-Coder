// CompanionSyncEngine.swift — DoomCoder Companion
// Stripped-down read-only CloudKit sync engine for iOS companion.
// Fetches: NotificationLog, MacStatus, AgentConfig, AgentIcon.
// One write capability: Send Test notification.

import Foundation
import CloudKit
import UIKit
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
    var firstFetchCompleted: Bool = false

    // MARK: - Private CloudKit plumbing

    private let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
    private var db: CKDatabase { container.privateCloudDatabase }
    private var zone: CKRecordZone { CKRecordZone(zoneName: CloudKitConstants.zoneName) }

    private var syncEngine: CKSyncEngine?
    private var subscriptionsReady = false
    private var setupInProgress = false

    /// Persistent server-record cache so MacStatus updates carry recordChangeTag
    private let serverRecords = ServerRecordCache(
        defaults: AppGroupCache.defaults,
        key: "ck.ios.serverRecords"
    )

    // MARK: - Defaults key for engine state

    private static let engineStateKey = "ck.engineState"
    private var sharedDefaults: UserDefaults { AppGroupCache.defaults }

    // MARK: - Lifecycle

    func start() {
        Task { await setupSyncEngine() }
        
        // Re-bootstrap when the iCloud account changes mid-session
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.setupSyncEngine() }
        }
        
        // Flush CKSyncEngine state to disk when iOS suspends us
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.persistEngineStateNow() }
        }
        
        // Fetch changes when app becomes active
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.fetchChanges() }
        }
    }

    func persistEngineStateNow() {
        sharedDefaults.synchronize()
        print("[CompanionSyncEngine] persistEngineStateNow: shared defaults synchronized")
    }

    // MARK: - Zone creation

    private func ensureZone() async {
        let z = CKRecordZone(zoneID: zone.zoneID)
        let op = CKModifyRecordZonesOperation(recordZonesToSave: [z], recordZoneIDsToDelete: nil)
        op.qualityOfService = .userInitiated
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            op.modifyRecordZonesResultBlock = { result in
                if case .failure(let err) = result {
                    if let cke = err as? CKError,
                       cke.code == .serverRecordChanged || cke.code == .unknownItem {
                        // Already exists — treat as success
                    } else {
                        print("[CompanionSyncEngine] ensureZone error: \(err)")
                    }
                }
                cont.resume()
            }
            db.add(op)
        }
    }

    // MARK: - Setup

    private func setupSyncEngine() async {
        guard !setupInProgress else {
            print("[CompanionSyncEngine] setupSyncEngine: re-entry guard — skipping")
            return
        }
        setupInProgress = true
        defer { setupInProgress = false }

        // Verify account status
        do {
            let status = try await container.accountStatus()
            accountAvailable = (status == .available)
        } catch {
            accountAvailable = false
            print("[CompanionSyncEngine] accountStatus error: \(error)")
        }

        guard accountAvailable else { return }

        // Ensure zone exists BEFORE constructing engine
        await ensureZone()

        if syncEngine != nil { syncEngine = nil }

        // Restore persisted engine state
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

        let engine = CKSyncEngine(config)
        syncEngine = engine
        
        // Re-assert the zone in the engine's database state
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone.zoneID))])

        // Register subscriptions once per launch
        if !subscriptionsReady {
            subscriptionsReady = true
            await ensureSubscriptions()
        }

        try? await engine.fetchChanges()
    }

    // MARK: - Public API

    func fetchChanges() async {
        guard let engine = syncEngine else { return }
        try? await engine.fetchChanges()
    }

    func handleRemoteNotification() async {
        SyncTelemetry.shared.record(.pushReceived, side: .ios)
        await fetchChanges()
    }

    // MARK: - Send Test Notification

    func sendTestNotification() async {
        guard let primary = MacStatusStore.shared.primary else {
            print("[CompanionSyncEngine] sendTestNotification: no primary Mac found")
            return
        }
        
        let testRecord = NotificationLogRecord(
            notifId: UUID().uuidString,
            sessionKey: "test-\(UUID().uuidString)",
            macId: primary.macId,
            macName: primary.name,
            agent: "claude",
            phase: NormalizedEventPhase.permissionNeeded.rawValue,
            rawEvent: "test",
            title: "Test Notification",
            body: "Sent from DoomCoder Companion iOS",
            channel: "iOS",
            success: true,
            ts: Date()
        )
        
        let ckRecord = testRecord.toCKRecord()
        
        let op = CKModifyRecordsOperation(recordsToSave: [ckRecord], recordIDsToDelete: nil)
        op.qualityOfService = .userInitiated
        op.savePolicy = .allKeys
        
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    print("[CompanionSyncEngine] Test notification sent successfully")
                case .failure(let error):
                    print("[CompanionSyncEngine] Test notification failed: \(error)")
                }
                cont.resume()
            }
            db.add(op)
        }
    }

    // MARK: - Emergency reset

    func resetLocalSyncState() async {
        print("[CompanionSyncEngine] resetLocalSyncState: starting")
        SyncTelemetry.shared.record(.engineError, side: .ios,
                                    detail: "user-initiated local sync reset")
        
        syncEngine = nil
        subscriptionsReady = false
        zoneReady = false
        firstFetchCompleted = false
        
        sharedDefaults.removeObject(forKey: Self.engineStateKey)
        sharedDefaults.synchronize()
        
        await setupSyncEngine()
        print("[CompanionSyncEngine] resetLocalSyncState: done")
    }

    // MARK: - Subscriptions

    private func ensureSubscriptions() async {
        await setupDatabaseSubscription()
        await setupNotificationLogSubscription()
    }

    /// Database-level subscription for silent content-available pushes
    private func setupDatabaseSubscription() async {
        let sub = CKDatabaseSubscription(subscriptionID: "companion-db-sub-v1")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        
        do {
            try await db.save(sub)
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            // Already exists
        } catch {
            print("[CompanionSyncEngine] Database subscription error: \(error)")
        }
    }

    /// NotificationLog subscription with pre-baked alertTitle/alertBody (v8 format)
    private func setupNotificationLogSubscription() async {
        // Clean up legacy subscription IDs so a single live subscription owns the channel.
        for legacyID in ["notif-log-v6", "notif-log-v7", "notif-log-v8"] {
            _ = try? await db.deleteSubscription(withID: legacyID)
        }

        let predicate = NSPredicate(value: true)
        let sub = CKQuerySubscription(
            recordType: CloudKitConstants.RecordType.notificationLog,
            predicate: predicate,
            subscriptionID: "notif-log-v9",
            options: [.firesOnRecordCreation]
        )
        sub.zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName)
        
        let info = CKSubscription.NotificationInfo()
        // For iOS to display a banner (not silent push), the NotificationInfo
        // must include user-visible alert content. Map the CKRecord's "title"
        // and "body" fields straight into aps.alert via APNs localization
        // substitution. The NSE then runs (because shouldSendMutableContent)
        // and can further enrich (icon attachment, interruption level, thread
        // id) without changing the title/body.
        info.titleLocalizationKey = "%@"
        info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey = "%@"
        info.alertLocalizationArgs = ["body"]
        info.soundName = "default"
        info.shouldBadge = true
        info.shouldSendMutableContent = true
        info.desiredKeys = ["agent", "title", "body", "sessionKey", "phase"]
        sub.notificationInfo = info
        
        do {
            try await db.save(sub)
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            // Already exists
        } catch {
            print("[CompanionSyncEngine] NotificationLog subscription error: \(error)")
        }
    }

    // MARK: - Record fan-out

    nonisolated private func handleFetched(_ record: CKRecord) {
        Task { @MainActor in
            switch record.recordType {
            case CloudKitConstants.RecordType.macStatus:
                if let r = MacStatusRecord(record) {
                    MacStatusStore.shared.upsert(r)
                    // Persist server record for changeTag
                    self.serverRecords.store(record)
                }
                
            case CloudKitConstants.RecordType.notificationLog:
                if let r = NotificationLogRecord(record) {
                    NotificationLogStore.shared.append(r)
                }
                
            case "AgentConfig":
                // Custom record type: { macId, agents, installedAgents, statuses, updatedAt, schemaVersion }
                guard let r = AgentConfigRecord(record) else { return }
                let agents = r.agents.compactMap { TrackedAgent(rawValue: $0) }
                let installed = r.installedAgents.compactMap { TrackedAgent(rawValue: $0) }
                var statusMap: [TrackedAgent: String] = [:]
                if !r.statuses.isEmpty,
                   let data = r.statuses.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    for (k, v) in dict {
                        if let a = TrackedAgent(rawValue: k) { statusMap[a] = v }
                    }
                }
                AgentListStore.shared.updateState(
                    agents: agents,
                    installed: installed,
                    statuses: statusMap,
                    macId: r.macId
                )
                
            case CloudKitConstants.RecordType.agentIcon:
                guard let agentStr = record["agent"] as? String,
                      let asset = record["pngAsset"] as? CKAsset,
                      let fileURL = asset.fileURL,
                      let data = try? Data(contentsOf: fileURL)
                else { return }
                
                let slug = TrackedAgent(rawValue: agentStr)?.iconSlug ?? agentStr
                AppGroupCache.writeIcon(slug: slug, data: data)
                if let url = AppGroupCache.iconURL(slug: slug) {
                    LocalStore.shared.upsertAgentIcon(slug: slug, fileURL: url)
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
            // Persist the engine state
            if let data = try? JSONEncoder().encode(e.stateSerialization) {
                await MainActor.run {
                    AppGroupCache.defaults.set(data, forKey: Self.engineStateKey)
                    self.lastSyncAt = Date()
                }
            }
            SyncTelemetry.shared.record(.stateUpdate, side: .ios)

        case .accountChange(let e):
            await MainActor.run {
                switch e.changeType {
                case .signIn:
                    self.accountAvailable = true
                case .signOut:
                    self.accountAvailable = false
                case .switchAccounts:
                    MacStatusStore.shared.clear()
                    AgentListStore.shared.clear()
                    NotificationLogStore.shared.clear()
                    self.accountAvailable = true
                @unknown default:
                    break
                }
            }

        case .fetchedRecordZoneChanges(let e):
            for change in e.modifications {
                let rtype = change.record.recordType
                SyncTelemetry.shared.record(.fetched, side: .ios, recordType: rtype)
                await MainActor.run {
                    self.handleFetched(change.record)
                }
                SyncTelemetry.shared.record(.applied, side: .ios, recordType: rtype)
            }
            await MainActor.run {
                self.zoneReady = true
                self.firstFetchCompleted = true
                self.lastSyncAt = Date()
            }

        case .sentRecordZoneChanges(let e):
            for save in e.savedRecords {
                SyncTelemetry.shared.record(.sent, side: .ios, recordType: save.recordType)
            }
            for fail in e.failedRecordSaves {
                let cke = fail.error
                SyncTelemetry.shared.record(.nacked, side: .ios,
                                            recordType: fail.record.recordType,
                                            detail: "\(cke.code.rawValue): \(cke.localizedDescription)")
                print("[CompanionSyncEngine] save failed on \(fail.record.recordID.recordName): \(cke.localizedDescription)")
            }

        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Read-only companion: no pending changes
        return nil
    }
}
