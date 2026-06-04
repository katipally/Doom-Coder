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
    /// v2.7: package-internal accessor for PeerStatusPublisher (and any
    /// future writer) that needs to enqueue record-zone changes against
    /// the same engine the read-side uses. Avoids spinning up a second
    /// CKSyncEngine + zone + subscription just to write heartbeats.
    var internalSyncEngine: CKSyncEngine? { syncEngine }
    private var subscriptionsReady = false
    private var setupInProgress = false
    private var fetchInProgress = false

    /// Repeating fetch while the app is foregrounded. Silent CloudKit pushes are
    /// throttled by iOS, so without this an open-but-idle app could go many
    /// minutes without picking up new Mac/agent state. Runs only in foreground.
    @ObservationIgnored private var _foregroundPollTimer: Timer?
    private let foregroundPollInterval: TimeInterval = 30

    /// 2-minute watchdog: if Mac's lastSeen grows stale while iOS is foregrounded,
    /// self-heals by triggering a fresh CloudKit fetch. Catches the case where
    /// setupSyncEngine() failed at launch and the engine was never initialised.
    @ObservationIgnored private var _macWatchdogTimer: Timer?
    private let macWatchdogInterval: TimeInterval = 120

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
        // v2.7: engine is allowed to run whenever iCloud is available.
        // The Connection store is auto-populated via
        // `ensureImplicitConnection` the first time a MacStatus record
        // arrives — the user doesn't have to do anything for the same-
        // Apple-ID path. Explicit CKShare pairing still goes through
        // IOSPairingCoordinator and posts its own .connectionsChanged.
        Task { await setupSyncEngine() }
        startForegroundPolling()
        // v2.7: start writing PeerStatus heartbeats so the Mac can
        // see this iOS device in its Connections tab. Symmetric to
        // CloudKitPusher.publishMacStatus on the Mac side.
        PeerStatusPublisher.shared.start()
        // v2.8: self-heal any per-share CKSyncEngines that were
        // registered against the wrong database (private instead of
        // shared). Idempotent.
        ShareSyncEngineRegistry.shared.reconcileAll()

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
                self.startForegroundPolling()
                if self.syncEngine == nil {
                    // Reset any stale in-progress guard from a background hang
                    // so the fresh setup attempt is not silently skipped.
                    self.setupInProgress = false
                    await self.setupSyncEngine()
                } else {
                    await self.fetchChanges()
                }
            }
        }
    }

    /// v2.7+: when a MacStatus record arrives via the engine (i.e. the
    /// implicit-iCloud path), synthesise a Connection so the Devices
    /// section has something to show and the Dashboard can render
    /// agents.
    /// v2.8: deterministic id (`implicit-<macId>`) + stable iosId
    /// (`IosDeviceId.current`) so re-fetches and re-installs collapse
    /// to the same row.
    private static func ensureImplicitConnection(for status: MacStatusRecord) {
        let store = ConnectionStore.shared
        let id = Connection.implicitConnectionId(macId: status.macId)
        // 1. Exact match on the deterministic id (the canonical path).
        if let existing = store.connections.first(where: { $0.id == id }) {
            var refreshed = existing
            refreshed.status = .active
            refreshed.lastSyncAt = status.lastSeen
            refreshed.iosDeviceId = IosDeviceId.current  // back-fill the stable id
            store.upsert(refreshed)
            return
        }
        // 2. Match on macDeviceId for any pre-v2.8 row that happened
        // to survive the wipe-on-upgrade migration (e.g. the user
        // restored a backup). Drop and re-create with the right id.
        if let _ = store.connections.first(where: { $0.macDeviceId == status.macId && $0.ckShareRef == nil && $0.id != id }) {
            // Don't accumulate. Wipe ALL rows for this Mac, then re-create
            // with the deterministic id. (One MacStatus arrival triggers
            // exactly one row; the legacy row was a duplicate.)
            for conn in store.connections where conn.macDeviceId == status.macId && conn.id != id {
                store.remove(id: conn.id)
            }
        }
        // 3. Fresh create with the deterministic id.
        let conn = Connection(
            id: id,
            macDeviceId: status.macId,
            iosDeviceId: IosDeviceId.current,
            route: .iCloud,
            status: .active,
            createdAt: Date(),
            lastSyncAt: status.lastSeen,
            ckShareRef: nil
        )
        store.upsert(conn)
        print("[CompanionSyncEngine] registered implicit iCloud connection for Mac \(status.macId.prefix(8))…")
    }

    /// v2.7: classify a fetched record as implicit-iCloud vs CKShare.
    /// The base engine always reads from the user's private DB, so by
    /// definition any record that arrives here is implicit-iCloud. The
    /// CKShare path routes through ShareSubscription → handleFetchedZoneChanges
    /// and does NOT call this method.
    private static func routeForRecord(_ status: MacStatusRecord) -> Route {
        return .iCloud
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

    /// Starts (or restarts) the foreground fetch timer. Idempotent.
    private func startForegroundPolling() {
        stopForegroundPolling()
        let t = Timer(timeInterval: foregroundPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.fetchChanges() }
        }
        RunLoop.main.add(t, forMode: .common)
        _foregroundPollTimer = t
        startMacWatchdog()
    }

    private func stopForegroundPolling() {
        _foregroundPollTimer?.invalidate()
        _foregroundPollTimer = nil
        stopMacWatchdog()
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

    private func startMacWatchdog() {
        _macWatchdogTimer?.invalidate()
        let t = Timer(timeInterval: macWatchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.healMacConnectionIfStale() }
        }
        RunLoop.main.add(t, forMode: .common)
        _macWatchdogTimer = t
    }

    private func stopMacWatchdog() {
        _macWatchdogTimer?.invalidate()
        _macWatchdogTimer = nil
    }

    private func healMacConnectionIfStale() async {
        guard let mac = MacStatusStore.shared.primary else { return }
        let age = -mac.lastSeen.timeIntervalSinceNow
        guard age > 180 else { return }  // < 3 min = fresh enough, do nothing
        if age > 600 {
            // Very stale (>10 min): wipe sync token and do a full re-fetch
            await forceFetchAll()
        } else {
            await fetchChanges()
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
    }

    /// Called by ShareSubscription when a per-share CKSyncEngine delivers
    /// records fetched from a paired Mac. v2.7 routes these through the
    /// same record fan-out as the implicit-iCloud path.
    func handleFetchedZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges, from connection: Connection) async {
        for change in event.modifications {
            let rtype = change.record.recordType
            SyncTelemetry.shared.record(.fetched, side: .ios, recordType: rtype)
            await MainActor.run {
                self.handleFetched(change.record)
            }
            // Mark the connection as recently synced.
            var updated = connection
            updated.lastSyncAt = Date()
            ConnectionStore.shared.upsert(updated)
            SyncTelemetry.shared.record(.applied, side: .ios, recordType: rtype)
        }
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
                    // v2.7: this is the implicit-iCloud path (same Apple ID,
                    // no explicit CKShare). The Mac's status landed in the
                    // user's private DB, which means the user has a
                    // working connection to this Mac even though we never
                    // created a CKShare. Auto-register a synthetic
                    // Connection so the Dashboard's Devices section
                    // shows it, the MacSwitcher works, and the
                    // "Add a Mac" CTA doesn't keep nagging.
                    if case .iCloud = Self.routeForRecord(r) {
                        Self.ensureImplicitConnection(for: r)
                    }
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
                }
            }
            // Always update sync timestamp and mark zone/fetch ready on state update —
            // stateUpdate fires after every fetchChanges() call regardless of whether
            // any records were returned, making it the reliable "sync completed" signal.
            await MainActor.run {
                self.lastSyncAt = Date()
                self.zoneReady = true
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
                // v2.7: clear the PeerStatus cache entry so the next
                // heartbeat builds against a fresh server-known base.
                if save.recordType == CloudKitConstants.RecordType.peerStatus {
                    await MainActor.run {
                        PeerStatusPublisherCache.shared.didSave(save)
                    }
                }
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
        // v2.7: the engine now also writes PeerStatus heartbeats (see
        // PeerStatusPublisher). The pending-change set is filtered by
        // the context's scope, then each record is materialised from
        // the matching cache (matching the Mac pusher's pattern of
        // building the CKRecord inside the batch closure to preserve
        // recordChangeTag).
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await MainActor.run {
                PeerStatusPublisherCache.shared.buildCKRecord(for: recordID)
            }
        }
    }
}
