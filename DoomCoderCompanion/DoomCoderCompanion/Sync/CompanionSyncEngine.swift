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

    /// v5.2: invoked (on the main actor) the first time `zoneReady`
    /// transitions from `false` to `true`. Used by `PeerStatusPublisher`
    /// to fire its first heart-beat with the real `macId` (the
    /// previous immediate-publish path was silently dropped because
    /// the CKSyncEngine wasn't ready yet — the first heart-beat went
    /// out with `macId = nil` and was never usable on the Mac side).
    var onZoneReady: (() -> Void)?

    // MARK: - Private CloudKit plumbing

    private let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
    private var db: CKDatabase { container.privateCloudDatabase }
    private var zone: CKRecordZone { CKRecordZone(zoneName: CloudKitConstants.zoneName) }

    private var syncEngine: CKSyncEngine?
    /// v2.7: package-internal accessor for PeerStatusPublisher (and any
    /// future writer) that needs to enqueue record-zone changes against
    /// the same engine the read-side uses. Avoids spinning up a second
    /// CKSyncEngine + zone + subscription just to write heartbeats.
    var internalSyncEngine: CKSyncEngine? { syncEngine }
    private var subscriptionsReady = false
    private var setupInProgress = false
    private var fetchInProgress = false
    /// Foreground fetch poll. APNs silent push is unreliable in dev/unsigned
    /// builds (OSStatus 13) and can be throttled even in Release, so while the
    /// app is active we pull changes on a light cadence. This is what makes a
    /// Mac-initiated pair request (CSC{requested}) surface promptly without a
    /// push. Cancelled on background; the heavy lifting is still push-driven.
    private var foregroundPollTask: Task<Void, Never>?
    private let foregroundPollInterval: UInt64 = 6_000_000_000  // 6s

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
        // Engine runs whenever iCloud is available. Connections are only
        // created through explicit QR pairing (IOSPairingCoordinator).
        // MacStatus records update status on existing connections only.
        Task { await setupSyncEngine() }
        // v2.7: start writing PeerStatus heartbeats so the Mac can
        // see this iOS device in its Connections tab. Symmetric to
        // CloudKitPusher.publishMacStatus on the Mac side.
        PeerStatusPublisher.shared.start()
        // v6: a SINGLE CKSyncEngine for the whole shared database (was
        // one-engine-per-share, which violated Apple's one-engine-per-DB
        // rule and dropped sync events).
        SharedDatabaseSync.shared.start()
        // v6.1: the Mac discovers same-iCloud iPhones directly from the
        // PeerStatus heartbeats it already receives (shared private zone) —
        // no public-DB presence record needed, so we don't publish one.

        // Re-bootstrap when the iCloud account changes mid-session
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.setupSyncEngine() }
        }

        // When iOS backgrounds us: persist state and do a final sync. Keep timers
        // alive — they continue firing for any background time iOS grants (silent
        // pushes get ~30s, BGAppRefreshTask gets ~30s). We request an explicit
        // background task slot so the final fetch can actually complete.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopForegroundPoll()
                self.persistEngineStateNow()
                self.beginBackgroundSync()
            }
        }

        // Fetch changes when app becomes active; re-attempt full setup if engine
        // never initialized (handles transient accountStatus failure at launch).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.syncEngine == nil {
                    // Reset any stale in-progress guard from a background hang
                    // so the fresh setup attempt is not silently skipped.
                    self.setupInProgress = false
                    await self.setupSyncEngine()
                } else {
                    await self.fetchChanges()
                }
                // v6 event-driven: also pull shared-DB changes and re-publish
                // presence/heartbeat on every activation (replaces the polling
                // timers).
                await SharedDatabaseSync.shared.fetchChanges()
                PeerStatusPublisher.shared.publishNow(force: true)
                self.startForegroundPoll()
            }
        }

        // Start the foreground poll right away (launch is a foreground event).
        startForegroundPoll()
    }

    // MARK: - Foreground fetch poll (push fallback)

    private func startForegroundPoll() {
        guard foregroundPollTask == nil else { return }
        foregroundPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.foregroundPollInterval)
                if Task.isCancelled { break }
                if self.syncEngine != nil {
                    await self.fetchChanges()
                }
            }
        }
    }

    private func stopForegroundPoll() {
        foregroundPollTask?.cancel()
        foregroundPollTask = nil
    }

    /// A Mac's `DeviceRecord` arrived on the PRIVATE engine. That only happens
    /// when the Mac is on the SAME Apple ID (a different-iCloud Mac's records
    /// arrive on the shared engine instead). So this is the same-iCloud path:
    /// refresh the existing connection, or CREATE one if the Mac initiated the
    /// pair from its picker. There is no ConnectionStateChange handshake
    /// anymore — the Mac's DeviceRecord simply appearing in our private zone IS
    /// the signal that we're paired with one of the user's own Macs. Creating
    /// the connection here ungates that Mac's device card, its agents and its
    /// notifications (all keyed on an active connection for the macId).
    @MainActor
    private static func refreshExistingConnections(for dev: DeviceRecord) {
        let store = ConnectionStore.shared
        let iosId = IosDeviceId.current
        let derived = DerivedDeviceState.derive(hasPairing: true, peer: dev)
        let status: ConnectionStatus = (derived == .active) ? .active : .suspended

        if let existing = store.connections.first(where: {
            $0.macDeviceId == dev.deviceId || ($0.macDeviceId.isEmpty && $0.iosDeviceId == iosId)
        }) {
            var updated = existing
            if updated.macDeviceId.isEmpty { updated.macDeviceId = dev.deviceId }
            updated.status = status
            updated.lastSyncAt = dev.lastSeen
            if updated.peerAccountName == nil { updated.peerAccountName = dev.accountName }
            if updated.peerAccountEmail == nil { updated.peerAccountEmail = dev.accountEmail }
            store.upsert(updated)
            return
        }

        // No connection yet → same-iCloud auto-connect.
        let id = Connection.implicitConnectionId(macId: dev.deviceId, iosDeviceId: iosId)
        let conn = Connection(
            id: id,
            macDeviceId: dev.deviceId,
            iosDeviceId: iosId,
            route: .iCloud,
            status: status,
            createdAt: Date(),
            lastSyncAt: dev.lastSeen,
            ckShareRef: nil,
            pairingOrigin: .sameICloud,
            stateChangeCounter: 1,
            shareAcceptedAt: Date(),
            peerAccountName: dev.accountName,
            peerAccountEmail: dev.accountEmail
        )
        store.upsert(conn)
        ConnectionNotifier.shared.notifyConnected(macName: dev.displayName)
        // Start writing our own DeviceRecord so the Mac sees us, and pull this
        // Mac's agents/notifications now that the active connection ungates them.
        PeerStatusPublisher.shared.publishNow(force: true)
        Task { await CompanionSyncEngine.shared.fetchChanges() }
    }

    /// Stops the engine, clears local stores, and resets state so the
    /// Dashboard shows the "Add a Mac" empty state. Safe to call
    /// multiple times. Does NOT touch ConnectionStore itself — the
    /// caller is responsible for the Connection lifecycle.
    private func tearDownEngine(reason: String) async {
        print("[CompanionSyncEngine] tearing down engine: \(reason)")
        syncEngine = nil
        subscriptionsReady = false
        zoneReady = false
        firstFetchCompleted = true  // don't spin the "Syncing with Mac…" forever
        lastSyncAt = nil
        // Wipe per-Mac data so the Dashboard renders the empty state
        // immediately, even if a stale fetch landed before the gate
        // was applied.
        MacStatusStore.shared.clear()
        AgentListStore.shared.clear()
        NotificationLogStore.shared.clear()
    }

    /// Requests a UIBackgroundTask slot and performs a final fetch before
    /// iOS suspends the app. Uses a class holder to avoid the mutation-after-capture
    /// Swift concurrency warning with UIBackgroundTaskIdentifier.
    private func beginBackgroundSync() {
        final class TaskHolder: @unchecked Sendable {
            var id: UIBackgroundTaskIdentifier = .invalid
        }
        let holder = TaskHolder()
        holder.id = UIApplication.shared.beginBackgroundTask(withName: "DoomCoder.sync") {
            UIApplication.shared.endBackgroundTask(holder.id)
        }
        Task { @MainActor [weak self] in
            await self?.fetchChanges()
            UIApplication.shared.endBackgroundTask(holder.id)
        }
    }

    func persistEngineStateNow() {
        sharedDefaults.synchronize()
        print("[CompanionSyncEngine] persistEngineStateNow: shared defaults synchronized")
    }

    // MARK: - Zone creation

    private func ensureZone() async -> Bool {
        let z = CKRecordZone(zoneID: zone.zoneID)
        let op = CKModifyRecordZonesOperation(recordZonesToSave: [z], recordZoneIDsToDelete: nil)
        op.qualityOfService = .userInitiated
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            op.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    cont.resume(returning: true)
                case .failure(let err):
                    if let cke = err as? CKError,
                       cke.code == .serverRecordChanged || cke.code == .unknownItem {
                        // Already exists — treat as success
                        cont.resume(returning: true)
                    } else {
                        print("[CompanionSyncEngine] ensureZone error: \(err)")
                        SyncTelemetry.shared.record(.engineError, side: .ios,
                                                    detail: "ensureZone: \(err.localizedDescription)")
                        cont.resume(returning: false)
                    }
                }
            }
            db.add(op)
        }
    }

    // MARK: - Setup

    private func setupSyncEngine() async {
        // v2.7: do not gate the engine on having an active Connection.
        // The implicit-iCloud path is the same iCloud subscription the
        // iOS app has always used — gating it would break users on the
        // same Apple ID who never went through an explicit pairing UI.
        // Instead: let the engine always run, and the
        // `ensureImplicitConnection` helper below auto-registers a
        // synthetic Connection the first time a MacStatus record
        // arrives. The Dashboard then knows which Mac this iOS app
        // is connected to without requiring the user to take action.
        guard !setupInProgress else {
            print("[CompanionSyncEngine] setupSyncEngine: re-entry guard — skipping")
            return
        }
        setupInProgress = true
        defer { setupInProgress = false }

        // Verify account status — retry up to 3 times for transient statuses
        // (.couldNotDetermine, .temporarilyUnavailable) common on first launch.
        var lastStatus: CKAccountStatus = .couldNotDetermine
        for attempt in 1...3 {
            do {
                lastStatus = try await container.accountStatus()
                if lastStatus != .couldNotDetermine && lastStatus != .temporarilyUnavailable { break }
            } catch {
                print("[CompanionSyncEngine] accountStatus error (attempt \(attempt)): \(error)")
            }
            if attempt < 3 { try? await Task.sleep(for: .seconds(2)) }
        }
        let statusName: String
        switch lastStatus {
        case .available:              statusName = "available"
        case .noAccount:              statusName = "noAccount"
        case .restricted:             statusName = "restricted"
        case .couldNotDetermine:      statusName = "couldNotDetermine"
        case .temporarilyUnavailable: statusName = "temporarilyUnavailable"
        @unknown default:             statusName = "unknown(\(lastStatus.rawValue))"
        }
        print("[CompanionSyncEngine] accountStatus: \(statusName)")
        accountAvailable = (lastStatus == .available)

        guard accountAvailable else {
            // Schedule a retry in 30 s so a transient account unavailability at
            // launch self-heals without requiring the user to reopen the app.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                await self?.setupSyncEngine()
            }
            return
        }

        // Ensure zone exists BEFORE constructing engine
        guard await ensureZone() else {
            SyncTelemetry.shared.record(.engineError, side: .ios, detail: "ensureZone failed — aborting setup")
            return
        }

        if syncEngine != nil {
            syncEngine = nil
            subscriptionsReady = false
        }

        // ── Engine state migration ───────────────────────────────────────
        // Detect which CloudKit environment this binary targets. Without an
        // explicit icloud-container-environment entitlement, Apple routes:
        //   Debug (dev certificate)   → Development CloudKit
        //   Release / TestFlight / AS → Production CloudKit
        // If the environment ever changes (e.g. a debug build briefly ran with a
        // Production entitlement), stale sync tokens from the old environment
        // will confuse the new engine. Wipe and re-fetch whenever the detected
        // environment differs from what was last recorded.
        #if DEBUG
        let currentEnv = "development"
        #else
        let currentEnv = "production"
        #endif
        let envKey = "ck.ios.environment.v2"
        let previousEnv = sharedDefaults.string(forKey: envKey)
        if previousEnv != currentEnv {
            let hasStaleState = sharedDefaults.data(forKey: Self.engineStateKey) != nil
            if hasStaleState {
                print("[CompanionSyncEngine] env migration: wiping stale state (\(previousEnv ?? "nil") → \(currentEnv))")
                sharedDefaults.removeObject(forKey: Self.engineStateKey)
                serverRecords.clear()
                DeviceRecordPublisherCache.shared.clear()
                MacStatusStore.shared.clear()
            }
            sharedDefaults.removeObject(forKey: "ck.ios.environment.v1")
            sharedDefaults.set(currentEnv, forKey: envKey)
        }

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

        do {
            try await engine.fetchChanges()
        } catch {
            SyncTelemetry.shared.record(.engineError, side: .ios,
                                        detail: "initial fetchChanges: \(error.localizedDescription)")
            print("[CompanionSyncEngine] initial fetchChanges error: \(error)")
            // Schedule one retry after 5 s so a transient CloudKit error on first
            // launch doesn't leave the user permanently stuck at "Mac not visible."
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.fetchChanges()
            }
        }
    }

    // MARK: - Public API

    /// v5.2: sets `zoneReady = true` exactly once and fires the
    /// `onZoneReady` callback (if set). Called from the two places
    /// in `handleEvent` that mark the engine ready. Idempotent —
    /// subsequent calls are a no-op so we don't re-fire the
    /// callback on every state update after the first one.
    @MainActor
    private func markZoneReady() {
        if zoneReady { return }
        zoneReady = true
        if let cb = onZoneReady {
            // Clear before invoking so a recursive call (e.g. the
            // callback calls fetchChanges which causes another
            // stateUpdate) doesn't double-fire.
            onZoneReady = nil
            cb()
        }
    }

    func fetchChanges() async {
        guard let engine = syncEngine else {
            // Engine not initialised yet (e.g. pull-to-refresh fired before
            // setup finished, or setup failed at launch). Attempt setup so a
            // manual refresh always does real work instead of silently no-oping.
            if !setupInProgress { await setupSyncEngine() }
            return
        }
        do {
            guard !fetchInProgress else { return }
            fetchInProgress = true
            defer { fetchInProgress = false }
            try await engine.fetchChanges()
        } catch {
            SyncTelemetry.shared.record(.engineError, side: .ios,
                                        detail: "fetchChanges: \(error.localizedDescription)")
            print("[CompanionSyncEngine] fetchChanges error: \(error)")
        }
    }

    /// Clears the saved sync token and re-initialises the engine so the next
    /// fetch retrieves ALL records from CloudKit — not just incremental changes.
    /// Lighter than resetLocalSyncState(): does not wipe stores or environment keys.
    func forceFetchAll() async {
        sharedDefaults.removeObject(forKey: Self.engineStateKey)
        sharedDefaults.synchronize()
        syncEngine = nil
        zoneReady = false
        firstFetchCompleted = false
        setupInProgress = false          // Clear guard so setupSyncEngine() runs
        await setupSyncEngine()
    }

    func handleRemoteNotification() async {
        SyncTelemetry.shared.record(.pushReceived, side: .ios)
        // If the engine never initialized (e.g. accountStatus failed at launch),
        // use the push arrival as an opportunity to re-attempt setup.
        if syncEngine == nil {
            await setupSyncEngine()
        }
        await fetchChanges()
        // v6: a silent push may be for a cross-account shared-zone change.
        await SharedDatabaseSync.shared.fetchChanges()
    }

    /// v6: called by the single shared-DB engine (SharedDatabaseSync) when it
    /// fetches a record from a paired Mac's shared zone (cross-account). Routes
    /// it through the same record fan-out as the private-engine path.
    func ingestSharedRecord(_ record: CKRecord) {
        SyncTelemetry.shared.record(.fetched, side: .ios, recordType: record.recordType)
        handleFetched(record)
        SyncTelemetry.shared.record(.applied, side: .ios, recordType: record.recordType)
    }

    // MARK: - Send Test Notification

    /// Sends a test NotificationLog to CloudKit. Returns `true` only once the
    /// write is confirmed by the server, `false` on failure — so the UI can
    /// report honestly instead of always showing "Sent ✓".
    @discardableResult
    func sendTestNotification() async -> Bool {
        guard let primary = MacStatusStore.shared.primary else {
            print("[CompanionSyncEngine] sendTestNotification: no primary Mac found")
            return false
        }

        let testRecord = NotificationLogRecord(
            notifId: UUID().uuidString,
            sessionKey: "test-\(UUID().uuidString)",
            macId: primary.deviceId,
            macName: primary.displayName,
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

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    print("[CompanionSyncEngine] Test notification sent successfully")
                    cont.resume(returning: true)
                case .failure(let error):
                    print("[CompanionSyncEngine] Test notification failed: \(error)")
                    cont.resume(returning: false)
                }
            }
            db.add(op)
        }
    }

    func resetLocalSyncState() async {
        print("[CompanionSyncEngine] resetLocalSyncState: starting")
        SyncTelemetry.shared.record(.engineError, side: .ios,
                                    detail: "user-initiated local sync reset")

        syncEngine = nil
        subscriptionsReady = false
        zoneReady = false
        firstFetchCompleted = false

        sharedDefaults.removeObject(forKey: Self.engineStateKey)
        sharedDefaults.removeObject(forKey: "ck.ios.environment.v1")
        sharedDefaults.removeObject(forKey: "ck.ios.environment.v2")
        sharedDefaults.synchronize()
        serverRecords.clear()
        DeviceRecordPublisherCache.shared.clear()

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
            case DeviceRecord.recordType:
                guard let dev = DeviceRecord(record) else { return }
                switch dev.role {
                case .mac:
                    // The Mac's presence/profile record. Upsert into the unified
                    // device store and refresh the liveness of any existing
                    // explicitly-paired connection. NO auto-attach.
                    MacStatusStore.shared.upsert(dev)
                    self.serverRecords.store(record)
                    Self.refreshExistingConnections(for: dev)
                case .ios:
                    // Our own record echoed back via the shared private zone —
                    // ignore (we are the writer).
                    break
                }

            case CloudKitConstants.RecordType.notificationLog:
                if let r = NotificationLogRecord(record) {
                    NotificationLogStore.shared.append(r)
                }

            case "AgentConfig":
                // Custom record type: { macId, agents, installedAgents, statuses, updatedAt, schemaVersion }
                guard let r = AgentConfigRecord(record) else { return }
                // v10: no ingestion gate. A same-iCloud Mac's DeviceRecord makes
                // us auto-connect to it (see refreshExistingConnections), so every
                // Mac whose AgentConfig reaches this private engine is one of the
                // user's own, paired Macs. Gating here previously dropped the
                // AgentConfig on the FIRST sync when it arrived in the same batch
                // before the Mac's DeviceRecord (which creates the connection) —
                // and CKSyncEngine never redelivers it. So we always ingest;
                // the device list / Mac switcher scope the UI per connection.
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

    /// v7: a Mac's DeviceRecord was deleted from the zone (the Mac disconnected
    /// / forgot this iPhone). Drop the matching local Connection + store entry
    /// so the iPhone list updates without waiting for a stale-prune.
    func ingestRecordDeletion(_ recordID: CKRecord.ID) {
        let name = recordID.recordName
        guard name.hasPrefix("Device-") else { return }
        let deviceId = String(name.dropFirst("Device-".count))
        guard !deviceId.isEmpty else { return }
        // Only react to a Mac's deletion (our own deletion uses our iosDeviceId).
        guard deviceId != IosDeviceId.current else { return }
        MacStatusStore.shared.remove(macId: deviceId)
        let toRemove = ConnectionStore.shared.connections.filter { $0.macDeviceId == deviceId }
        for conn in toRemove {
            ConnectionStore.shared.remove(id: conn.id)
            Task { await LocalStore.shared.clearMacData(macId: conn.macDeviceId) }
        }
        if !toRemove.isEmpty {
            ConnectionNotifier.shared.notifyDisconnected(macName: nil)
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
                }
            }
            // Always update sync timestamp and mark zone/fetch ready on state update —
            // stateUpdate fires after every fetchChanges() call regardless of whether
            // any records were returned, making it the reliable "sync completed" signal.
            await MainActor.run {
                self.lastSyncAt = Date()
                self.markZoneReady()
                self.firstFetchCompleted = true
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
                    self.serverRecords.clear()
                    DeviceRecordPublisherCache.shared.clear()
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
                    // v7: NO auto-attach. A same-account MacStatus arriving here
                    // only refreshes status for an ALREADY-paired Mac (handled in
                    // handleFetched → refreshExistingConnections). A connection is
                    // created exclusively by an explicit user action: accepting a
                    // Mac-initiated pair request, or the same-iCloud code/QR flow.
                }
                SyncTelemetry.shared.record(.applied, side: .ios, recordType: rtype)
            }
            // v7: a deleted Mac DeviceRecord (same-iCloud) means that Mac
            // disconnected — drop the matching local connection.
            for deletion in e.deletions {
                await MainActor.run { self.ingestRecordDeletion(deletion.recordID) }
            }
            await MainActor.run {
                self.markZoneReady()
                self.firstFetchCompleted = true
                self.lastSyncAt = Date()
            }

        case .sentRecordZoneChanges(let e):
            for save in e.savedRecords {
                SyncTelemetry.shared.record(.sent, side: .ios, recordType: save.recordType)
                // v7: clear the DeviceRecord cache entry so the next heartbeat
                // builds against a fresh server-known base (preserved etag).
                if save.recordType == DeviceRecord.recordType {
                    await MainActor.run {
                        DeviceRecordPublisherCache.shared.didSave(save)
                    }
                }
            }
            for fail in e.failedRecordSaves {
                let cke = fail.error
                SyncTelemetry.shared.record(.nacked, side: .ios,
                                            recordType: fail.record.recordType,
                                            detail: "\(cke.code.rawValue): \(cke.localizedDescription)")
                print("[CompanionSyncEngine] save failed on \(fail.record.recordID.recordName): \(cke.localizedDescription)")

                // Apple requires the app to resolve `serverRecordChanged` itself
                // (CKSyncEngine docs). DeviceRecord has a stable recordID
                // ("Device-<id>") re-saved on every heartbeat, so without the
                // etag self-heal the heartbeat would wedge on 14/2004.
                let recordID = fail.record.recordID
                guard fail.record.recordType == DeviceRecord.recordType else { continue }
                switch cke.code {
                case .serverRecordChanged:
                    if let server = cke.serverRecord {
                        await MainActor.run {
                            DeviceRecordPublisherCache.shared.noteServerRecord(server)
                        }
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    }
                case .unknownItem:
                    // Record was deleted server-side — drop the stale etag and
                    // re-enqueue so the next save INSERTs cleanly.
                    await MainActor.run {
                        DeviceRecordPublisherCache.shared.forgetServerRecord(recordID)
                    }
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                default:
                    break
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
        // v7: the engine writes the iPhone's own DeviceRecord(role: .ios)
        // heartbeats (see PeerStatusPublisher). Materialise each pending record
        // from the DeviceRecord cache, preserving recordChangeTag.
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await MainActor.run {
                DeviceRecordPublisherCache.shared.buildCKRecord(for: recordID)
            }
        }
    }
}
