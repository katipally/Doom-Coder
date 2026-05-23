import Foundation
import CloudKit
import IOKit
import AppKit
import OSLog
import DoomCoderCore

/// Single sync surface between the Mac app and iCloud (private DB).
///
/// Migrated from manual CKModifyRecordsOperation + 400ms coalesce queue
/// to CKSyncEngine (macOS 14+). Benefits:
///   • Automatic retry and back-off on network errors.
///   • Engine state serialised to UserDefaults — pending writes survive
///     clean and unclean process exits.
///   • Delta-based fetches (token tracked by CKSyncEngine) rather than
///     re-fetching the whole Settings singleton on every push.
///   • Per-batch save-policy: Settings uses .changedKeys for per-field LWW;
///     heartbeat records (MacStatus, Session, etc.) use .allKeys so we
///     never need to track change-tags for write-often records.
///
/// All public mutating API is @MainActor; delegate callbacks are nonisolated
/// and hop to MainActor via Task.detached { @MainActor in … }.
@MainActor
@Observable
final class CloudKitSyncEngine {

    static let shared = CloudKitSyncEngine()

    // MARK: - Public state (UI-bindable)

    private(set) var isAvailable: Bool = false
    private(set) var accountStatusText: String = "Checking iCloud…"
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var pendingWrites: Int = 0

    /// Posted after applyRemoteSettings(_:) updates local state.
    static let settingsChangedNotification = Notification.Name("DoomCoderSettingsChanged")

    /// True while applyRemoteSettings is mutating local state; edit paths
    /// check this flag to skip re-publishing values that came from CloudKit.
    private(set) var applyingRemoteSettings: Bool = false

    // MARK: - Identity

    let macId: String = {
        let dict = IOServiceMatching("IOPlatformExpertDevice")
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, dict)
        defer { if svc != 0 { IOObjectRelease(svc) } }
        guard svc != 0,
              let cf = IORegistryEntryCreateCFProperty(svc, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        else { return UUID().uuidString }
        return (cf.takeRetainedValue() as? String) ?? UUID().uuidString
    }()

    var macName: String { Host.current().localizedName ?? "Mac" }

    // MARK: - Private CloudKit plumbing

    private nonisolated let logger = Logger(subsystem: "com.doomcoder", category: "cloudkit")
    private let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
    var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName,
                                         ownerName: CKCurrentUserDefaultName)

    // MARK: - CKSyncEngine

    private var syncEngine: CKSyncEngine?
    nonisolated static let engineStateKey = "ck.mac.engineState"

    /// Records awaiting a `.allKeys` save: MacStatus, Session, Event,
    /// NotificationLog, ControlCommand echo. We do not track change-tags
    /// for these write-often heartbeat records so .allKeys is correct.
    private var regularRecordsByID: [CKRecord.ID: CKRecord] = [:]

    /// Records awaiting a `.changedKeys` save: Settings only.
    /// CKSyncEngine uses changedKeys here so that concurrent iOS edits to
    /// different settings fields survive without being clobbered.
    private var settingsRecordsByID: [CKRecord.ID: CKRecord] = [:]

    /// Tracks in-flight ControlCommand acks (appliedAt stamped locally but
    /// save not yet confirmed by CloudKit). Used by recoverFromServerRecordChanged
    /// to re-enqueue the ack against a fresh recordChangeTag after a 14/2004,
    /// instead of silently dropping the ack and leaving iOS waiting forever.
    private var pendingCommandAcks: [CKRecord.ID: ControlCommandRecord] = [:]

    // MARK: - Settings state

    private var currentSettings: SettingsRecord?
    private var settingsSaveSerial: UInt64 = 0

    /// Persistent server-record cache (system fields only) for all records
    /// with stable IDs that we re-save across launches: SettingsRecord
    /// (singleton), MacStatusRecord (per macId), ControlCommandRecord (per
    /// commandId, Mac acks them). Without on-disk persistence of the
    /// recordChangeTag, every relaunch re-INSERTs and CloudKit responds
    /// with 14/2004 ("record to insert already exists") forever.
    private let serverRecords = ServerRecordCache(
        defaults: .standard,
        key: "ck.mac.serverRecords"
    )

    // MARK: - Timers

    private var heartbeatTimer: Timer?
    /// Safety-net fetch timer (30 s) — catches changes missed by silent push
    /// (APNs delivery is best-effort; Mac may be asleep, push may be dropped).
    /// Primary instant-sync path is push → fetchChanges(); this is the backstop.
    private var fetchTimer: Timer?
    private var pruneTimer: Timer?
    private var reauthScheduled = false
    private var bootstrapping = false

    // MARK: - Init

    private init() {}

    // MARK: - Lifecycle

    func start() {
        logger.info("CloudKitSyncEngine.start() macId=\(self.macId, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            await self.refreshAccountStatus()
            NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshAccountStatus() }
            }
        }
        // Fetch immediately when the Mac wakes from sleep — iOS may have sent
        // commands or settings changes while the Mac was offline.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logger.info("Mac wake detected — fetching CloudKit changes")
                await self?.fetchChanges()
            }
        }
    }

    func refreshAccountStatusNow() async { await refreshAccountStatus() }

    private func refreshAccountStatus() async {
        do {
            let status = try await container.accountStatus()
            logger.info("accountStatus -> \(String(describing: status), privacy: .public)")
            switch status {
            case .available:
                await bootstrap()
            case .noAccount:
                isAvailable = false
                accountStatusText = "Sign in to iCloud to sync the iOS companion"
            case .restricted:
                isAvailable = false
                accountStatusText = "iCloud restricted"
            case .couldNotDetermine:
                isAvailable = false
                accountStatusText = "iCloud unavailable"
            case .temporarilyUnavailable:
                isAvailable = false
                accountStatusText = "iCloud temporarily unavailable"
            @unknown default:
                isAvailable = false
                accountStatusText = "iCloud unknown state"
            }
        } catch {
            isAvailable = false
            accountStatusText = "iCloud error"
            lastError = error.localizedDescription
            logger.error("accountStatus failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func bootstrap() async {
        // Prevent concurrent or duplicate bootstraps. CKAccountChanged can
        // fire during ensureSubscriptionsBestEffort(), causing a second call
        // while the first is still in-flight; a second CKSyncEngine instance
        // for the same zone creates a conflict storm.
        guard !bootstrapping && syncEngine == nil else {
            logger.info("bootstrap: re-entry guard — skipping duplicate invocation")
            return
        }
        bootstrapping = true
        defer { bootstrapping = false }

        // Step 1: zone (idempotent on the server). CKSyncEngine does not
        // create zones automatically — we must ensure it exists first.
        do {
            try await ensureZone()
            logger.info("ensureZone OK")
        } catch {
            lastError = error.localizedDescription
            logger.error("ensureZone failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Step 2: init CKSyncEngine, restoring persisted state so in-flight
        // writes from the previous session are re-queued automatically.
        let serialization: CKSyncEngine.State.Serialization? = {
            guard let data = UserDefaults.standard.data(forKey: Self.engineStateKey),
                  let s = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            else { return nil }
            return s
        }()
        let config = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serialization,
            delegate: self
        )
        syncEngine = CKSyncEngine(config)

        // Step 2b: re-assert the zone in engine state. CKSyncEngine does NOT
        // auto-track custom zones across launches even when the zone exists
        // on the server. Without this, restored engine state emits the
        // "finished fetching changes for a zone that it never started"
        // warning and skips delta fetches. Idempotent: `.saveZone` is a
        // no-op if the engine already considers the zone created.
        let zone = CKRecordZone(zoneID: zoneID)
        syncEngine?.state.add(pendingDatabaseChanges: [.saveZone(zone)])

        // Step 3: signal availability. All publish methods gate on isAvailable.
        isAvailable = true
        accountStatusText = "iCloud synced"

        // Step 3a: register for APNs as early as possible. CKSubscription pushes
        // are silent (content-available); the device must be registered before
        // the first push or it is dropped. Doing this before fetchChanges()
        // closes the window where the very first iOS->Mac edit could be missed.
        await MainActor.run { NSApplication.shared.registerForRemoteNotifications() }
        logger.info("registerForRemoteNotifications requested (early)")

        // Step 3b: pre-warm ServerRecordCache for the two stable records we
        // always own (MacStatus-{macId} + Settings-singleton). On the very
        // first launch after a re-install / new build / account switch the
        // on-disk cache is empty, so without this the first publishMacStatus
        // emits a tag-less INSERT that CloudKit rejects with 14/2004
        // ("record to insert already exists") until the recovery path
        // catches up. Best-effort: missing records are normal on a true
        // first-ever launch.
        await prewarmStableRecordCache()

        // Step 4: initial MacStatus heartbeat.
        publishMacStatus()
        logger.info("initial MacStatus enqueued")

        // Step 5: subscriptions (best-effort; push is a nice-to-have).
        await ensureSubscriptionsBestEffort()

        // Step 7: delta-fetch to apply any Settings or ControlCommand records
        // written by iOS while the Mac was offline.
        try? await syncEngine?.fetchChanges()

        // Step 8: safety-net drain for ControlCommands that CKSyncEngine
        // state hasn't seen yet (first-launch, token reset, etc.).
        await ControlCommandRouter.drainPending()

        // Step 9: 90 s heartbeat so iOS sees a fresh lastSeen regularly.
        startHeartbeat()

        // Step 9b: 30 s fetch safety-net — catches iOS changes missed by push.
        startFetchTimer()

        // Step 10: daily CloudKit Event pruning.
        startPruneTimer()
    }

    // MARK: - Publish API

    func publishMacStatus() {
        guard isAvailable else { return }
        let sm = SleepManager.shared
        let net = NetworkInterfaces.primaryWoLDescriptor()
        let rec = MacStatusRecord(
            macId: macId, name: macName,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0.0",
            sleepActive: sm.isActive,
            mode: sm.mode.rawValue,
            sessionEndsAt: nil,
            lastSeen: Date(),
            thermalState: sm.thermalStateText,
            macAddress: net.macAddress,
            broadcastIPv4: net.broadcastIPv4
        )
        enqueue(save: rec.toCKRecord(base: serverRecords.record(forName: "MacStatus-\(macId)")))
    }

    /// Synchronously publishes an "offline" MacStatus before the Mac process
    /// exits. Bypasses the async enqueue path with a direct
    /// CKModifyRecordsOperation + DispatchSemaphore so the record has a
    /// chance to reach CloudKit within the ~3 s the OS gives us in
    /// applicationWillTerminate.
    func publishOfflineMacStatusSync() {
        guard isAvailable else { return }
        let sm = SleepManager.shared
        let rec = MacStatusRecord(
            macId: macId, name: macName,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0.0",
            sleepActive: false,
            mode: sm.mode.rawValue,
            sessionEndsAt: nil,
            lastSeen: Date(),
            thermalState: "offline"
        )
        let op = CKModifyRecordsOperation(recordsToSave: [rec.toCKRecord()], recordIDsToDelete: nil)
        op.savePolicy = .allKeys
        op.qualityOfService = .userInteractive
        let sema = DispatchSemaphore(value: 0)
        op.modifyRecordsResultBlock = { [logger] result in
            if case .failure(let e) = result {
                logger.error("offline MacStatus failed: \(e.localizedDescription, privacy: .public)")
            }
            sema.signal()
        }
        database.add(op)
        _ = sema.wait(timeout: .now() + 3)
    }

    /// Defensive flush hook called from `applicationWillTerminate`. The
    /// `.stateUpdate` event handler is the canonical persistence path — it
    /// fires after every state mutation and writes to UserDefaults. This
    /// just forces the standard defaults to flush dirty pages to disk so a
    /// hard crash immediately after a recent .stateUpdate cannot strand the
    /// delta-change token in the in-memory plist.
    nonisolated func persistEngineStateNow() {
        UserDefaults.standard.synchronize()
        logger.info("persistEngineStateNow: UserDefaults synchronized")
    }

    func publishSession(_ s: AgentTrackingManager.Session) {
        guard isAvailable else { return }
        let rec = SessionRecord(
            sessionKey: s.id, macId: macId,
            agent: s.agent.rawValue, sessionId: s.sessionId,
            cwd: s.cwd, cwdBase: NotificationCopy.shortCwd(s.cwd),
            startedAt: s.startedAt, updatedAt: s.updatedAt,
            lastEvent: s.lastEvent, lastPhase: s.lastPhase.rawValue,
            lastTool: s.lastTool,
            toolCallCount: s.toolCallCount,
            errorCount: s.errorCount,
            awaitingPermission: s.awaitingPermission,
            hasEnded: s.hasEnded, hasFailed: s.hasFailed,
            displayState: s.displayState.rawValue
        )
        enqueue(save: rec.toCKRecord(base: serverRecords.record(for: rec.recordID)))
    }

    func publishEvent(sessionKey: String, agent: String, event: String,
                      phase: String, tool: String?, path: String?,
                      ts: Date, payloadSnippet: String? = nil) {
        guard isAvailable else { return }
        let includeSnippet = UserDefaults.standard.bool(forKey: "doomcoder.privacy.includePayloadSnippets")
        let rec = EventRecord(
            sessionKey: sessionKey, macId: macId, agent: agent,
            rawEvent: event, phase: phase, tool: tool, path: path,
            ts: ts,
            payloadDigest: payloadSnippet.flatMap { sha256($0) },
            payloadSnippet: includeSnippet ? payloadSnippet : nil
        )
        enqueue(save: rec.toCKRecord())
    }

    func publishNotification(sessionKey: String, agent: String, phase: String,
                             event: String, title: String, body: String,
                             channel: String, success: Bool, ts: Date,
                             lastTool: String?, cwdBase: String?) {
        guard isAvailable else { return }
        let rec = NotificationLogRecord(
            sessionKey: sessionKey, macId: macId, macName: macName,
            agent: agent, phase: phase, rawEvent: event,
            title: title, body: body, channel: channel,
            success: success, ts: ts,
            lastTool: lastTool, cwdBase: cwdBase
        )
        enqueue(save: rec.toCKRecord())
    }

    func publishSettingsField(_ field: String, applyTo: (inout SettingsRecord) -> Void) {
        guard isAvailable, !applyingRemoteSettings else { return }
        var s = currentSettings ?? localSettingsSnapshot()
        applyTo(&s)
        s.touch(field, by: macId)
        currentSettings = s
        scheduleSettingsSave(s)
    }

    func publishSettingsTouching(_ touchedFields: [String]) {
        guard isAvailable, !applyingRemoteSettings else { return }
        var s = localSettingsSnapshot()
        s.updatedAt = currentSettings?.updatedAt ?? s.updatedAt
        let now = Date()
        for f in touchedFields { s.touch(f, at: now, by: macId) }
        currentSettings = s
        scheduleSettingsSave(s)
    }

    func publishSettingsTouchingPerAgent(agent: String, subs: [String]) {
        guard isAvailable, !applyingRemoteSettings else { return }
        var s = localSettingsSnapshot()
        s.updatedAt = currentSettings?.updatedAt ?? s.updatedAt
        let now = Date()
        for sub in subs { s.touchPerAgent(agent, sub: sub, at: now, by: macId) }
        currentSettings = s
        scheduleSettingsSave(s)
    }

    private func scheduleSettingsSave(_ settings: SettingsRecord) {
        settingsSaveSerial &+= 1
        let serial = settingsSaveSerial
        Task { @MainActor [self] in
            await enqueueSettingsSaveAfterPreflight(settings, serial: serial)
        }
    }

    private func enqueueSettingsSaveAfterPreflight(_ settings: SettingsRecord, serial: UInt64) async {
        guard isAvailable, !applyingRemoteSettings else { return }

        let fresh = await fetchRecordByID(SettingsRecord.recordID)
        var merged = settings
        if let fresh {
            serverRecords.store(fresh)
            if let remote = SettingsRecord(fresh) {
                merged.merge(with: remote)
            }
        }

        guard serial == settingsSaveSerial else { return }
        currentSettings = merged
        enqueue(save: merged.toCKRecord(base: fresh ?? serverRecords.record(forName: SettingsRecord.singletonRecordName)))
    }

    func acknowledgeCommand(_ record: ControlCommandRecord) {
        guard isAvailable else { return }
        // Track this ack so recoverFromServerRecordChanged can re-enqueue it
        // if the first attempt fails with 14/2004 (missing recordChangeTag).
        pendingCommandAcks[record.recordID] = record
        // Mutate the cached server CKRecord (carrying its recordChangeTag)
        // rather than constructing a fresh one. Without the tag, CloudKit
        // treats the ack as an insert and rejects with 14/2004.
        let base = serverRecords.record(for: record.recordID)
        let ck = record.toCKRecord(base: base)
        enqueue(save: ck)
    }

    /// Caches a server CKRecord's system fields (including recordChangeTag)
    /// so subsequent saves of this record are treated as UPDATEs rather than
    /// INSERTs. Called by ControlCommandRouter.drainPending() which fetches
    /// via CKQuery (not CKSyncEngine delta) and must prime the cache manually.
    func cacheRecord(_ ck: CKRecord) {
        serverRecords.store(ck)
    }

    // MARK: - Fetch

    /// Triggers a CKSyncEngine delta fetch. Delivers fetchedRecordZoneChanges
    /// which handles Settings (via applyRemoteSettings) and ControlCommands
    /// (via ControlCommandRouter.apply). Replaces the old fetchSettings() +
    /// drainPending() pair for the push-wakeup path.
    func fetchSettings() async {
        try? await syncEngine?.fetchChanges()
    }

    func fetchChanges() async {
        try? await syncEngine?.fetchChanges()
    }

    /// Recovery path for `.serverRecordChanged` (CKError 14/2004). Fetches
    /// the live record by ID via an explicit CKFetchRecordsOperation so we
    /// re-acquire the recordChangeTag (CKSyncEngine.fetchChanges only
    /// delivers deltas; if the server side hasn't changed, the conflicting
    /// record is never re-delivered). Then either:
    ///   • For singletons we own (MacStatus, Settings): persist the fresh
    ///     server record + re-enqueue our local save against the new tag.
    ///   • For ControlCommand acks: the iOS side keeps writing too — we
    ///     just refresh the cache; if there's still local state to ack the
    ///     router will re-enqueue it on the next fetchedRecordZoneChanges.
    private nonisolated func recoverFromServerRecordChanged(id: CKRecord.ID, recordType: String) async {
        // Drop stale pending change first; we'll re-enqueue after we have
        // the fresh tag (avoids the engine retrying the tagless save while
        // we're fetching).
        if let engine = await MainActor.run(body: { self.syncEngine }) {
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
        }
        await MainActor.run {
            self.regularRecordsByID.removeValue(forKey: id)
            self.settingsRecordsByID.removeValue(forKey: id)
        }

        // Explicit fetch by ID so we get the current tag even when there's
        // no delta token change.
        let db: CKDatabase = await MainActor.run { self.database }
        let fresh: CKRecord? = await withCheckedContinuation { (cont: CheckedContinuation<CKRecord?, Never>) in
            let op = CKFetchRecordsOperation(recordIDs: [id])
            op.qualityOfService = .userInitiated
            var got: CKRecord?
            op.perRecordResultBlock = { _, result in
                if case .success(let r) = result { got = r }
            }
            op.fetchRecordsResultBlock = { _ in cont.resume(returning: got) }
            db.add(op)
        }
        guard let fresh else {
            self.logger.notice("recover: fetch by ID returned nil for \(id.recordName, privacy: .public) — dropping")
            return
        }

        await MainActor.run {
            self.serverRecords.store(fresh)
            // Re-enqueue our local save against the freshly tagged record.
            switch recordType {
            case CloudKitConstants.RecordType.settings:
                if let s = self.currentSettings {
                    self.enqueue(save: s.toCKRecord(base: fresh))
                }
            case CloudKitConstants.RecordType.macStatus
                 where id.recordName == "MacStatus-\(self.macId)":
                self.publishMacStatus()
            case CloudKitConstants.RecordType.controlCommand:
                // fresh is now cached with the correct recordChangeTag.
                // If Mac had a pending ack (appliedAt stamped locally but
                // save failed with 14/2004), re-enqueue it against the
                // fresh tag so iOS eventually receives the confirmation.
                if let pendingAck = self.pendingCommandAcks[id] {
                    self.enqueue(save: pendingAck.toCKRecord(base: fresh))
                }
                // If no pending ack the command hasn't been applied yet —
                // the next fetchChanges or drainPending will deliver it
                // correctly now that the tag is cached.
            case CloudKitConstants.RecordType.session:
                // Re-publish the live session against the fresh tag so the
                // pending phase/tool/count update isn't silently dropped.
                // sessionKey is the recordName without the "Session-" prefix
                // (publishSession only replaces ' ' with '_', and our
                // sessionKey "{agentRaw}::{sessionId}" never contains
                // spaces in practice).
                let prefix = "Session-"
                guard id.recordName.hasPrefix(prefix) else { break }
                let sessionKey = String(id.recordName.dropFirst(prefix.count))
                if let live = AgentTrackingManager.shared.sessions[sessionKey] {
                    self.publishSession(live)
                }
            default:
                break
            }
        }
    }

    // MARK: - Enqueue

    private func enqueue(save record: CKRecord) {
        let isSettings = record.recordType == CloudKitConstants.RecordType.settings
        if isSettings {
            settingsRecordsByID[record.recordID] = record
        } else {
            regularRecordsByID[record.recordID] = record
        }
        pendingWrites = regularRecordsByID.count + settingsRecordsByID.count
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    }

    // MARK: - Incoming record fan-out

    /// Called from `handleEvent` via `await MainActor.run { }` so the
    /// CKRecord is transferred to the MainActor region before the
    /// Task.detached captures it — required by Swift 6 region checking.
    private nonisolated func scheduleHandleFetched(_ record: CKRecord) {
        Task { @MainActor [self] in
            switch record.recordType {
            case CloudKitConstants.RecordType.settings:
                self.serverRecords.store(record)
                guard let remote = SettingsRecord(record) else {
                    let keys = record.allKeys().joined(separator: ",")
                    self.logger.error("handleFetched: SettingsRecord decode FAILED — record=\(record.recordID.recordName, privacy: .public) tag=\(record.recordChangeTag ?? "nil", privacy: .public) keys=[\(keys, privacy: .public)]. Push silently dropped — investigate schema drift.")
                    return
                }
                var local = self.localSettingsSnapshot()
                local.merge(with: remote)
                self.currentSettings = local
                self.applyRemoteSettings(local)

            case CloudKitConstants.RecordType.macStatus:
                // Cache our own MacStatus server record so the next
                // heartbeat carries the recordChangeTag.
                if record.recordID.recordName == "MacStatus-\(self.macId)" {
                    self.serverRecords.store(record)
                }

            case CloudKitConstants.RecordType.session:
                // Cache server CKRecord so subsequent publishSession calls
                // (toolCallCount / lastEvent / phase updates) carry the
                // recordChangeTag and avoid the 14/2004 conflict flood.
                self.serverRecords.store(record)

            case CloudKitConstants.RecordType.controlCommand:
                // Cache the server CKRecord so acknowledgeCommand can mutate
                // it (preserving recordChangeTag) instead of creating a
                // fresh CKRecord that CloudKit treats as an insert.
                self.serverRecords.store(record)
                if let cmd = ControlCommandRecord(record) {
                    await ControlCommandRouter.apply(cmd)
                }

            default:
                break
            }
        }
    }

    // MARK: - Settings application

    private func applyRemoteSettings(_ s: SettingsRecord) {
        applyingRemoteSettings = true
        defer { applyingRemoteSettings = false }

        let ud = UserDefaults.standard
        ud.set(s.masterEnabled, forKey: "doomcoder.masterEnabled")
        if SleepManager.shared.isActive != s.masterEnabled {
            if s.masterEnabled { SleepManager.shared.enable() }
            else { SleepManager.shared.disable() }
        }
        if let mode = DoomCoderMode(rawValue: s.mode), SleepManager.shared.mode != mode {
            SleepManager.shared.mode = mode
        }
        if SleepManager.shared.sessionTimerHours != s.sessionTimerHrs {
            SleepManager.shared.sessionTimerHours = s.sessionTimerHrs
        }
        if SleepManager.shared.screenOffRearmMinutes != s.screenOffRearmMin {
            SleepManager.shared.screenOffRearmMinutes = s.screenOffRearmMin
        }
        ud.set(s.autoRevertSec, forKey: "doomcoder.session.autoRevertSeconds")
        EventStore.retentionDays = s.retentionDays
        ud.set(s.includePayloadSnippets, forKey: "doomcoder.privacy.includePayloadSnippets")

        var store = ChannelStore.load()
        store.global = ChannelStore.ChannelConfig(
            macNotification: s.channelMacEnabled,
            iOSCompanion: s.channeliOSEnabled
        )
        if let data = s.perAgentOverridesJSON.data(using: .utf8),
           let map = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) {
            store.perAgent = map.reduce(into: [:]) { acc, kv in
                acc[kv.key] = ChannelStore.ChannelConfig(
                    macNotification: kv.value["mac"] ?? true,
                    iOSCompanion: kv.value["ios"] ?? true
                )
            }
        }
        ChannelStore.save(store)

        if let data = s.perAgentOverridesJSON.data(using: .utf8),
           let map = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) {
            for agent in TrackedAgent.allCases {
                if let tracking = map[agent.rawValue]?["tracking"] {
                    TrackingStore.setEnabled(agent, tracking)
                }
            }
        }

        ChannelStore.savePrefs(ChannelStore.NotificationPrefs(
            sessionStart: s.prefSessionStart,
            sessionEnd: s.prefSessionEnd,
            error: s.prefError,
            permissionNeeded: s.prefPermissionNeeded,
            agentResponse: s.prefAgentResponse,
            subagentStart: s.prefSubagentStart,
            subagentEnd: s.prefSubagentEnd,
            toolUse: s.prefToolUse
        ))

        NotificationCenter.default.post(name: Self.settingsChangedNotification, object: nil)
    }

    private func localSettingsSnapshot() -> SettingsRecord {
        let ud = UserDefaults.standard
        let prefs = ChannelStore.loadPrefs()
        let channels = ChannelStore.load().global
        let perAgent = ChannelStore.load().perAgent
        let perAgentJSON: String = {
            var mapped: [String: [String: Bool]] = [:]
            for agent in TrackedAgent.allCases {
                let ch = perAgent[agent.rawValue]
                mapped[agent.rawValue] = [
                    "mac":       ch?.macNotification ?? true,
                    "ios":       ch?.iOSCompanion    ?? true,
                    "tracking":  TrackingStore.isEnabled(agent),
                    "installed": AgentInstallerV2.isInstalled(agent)
                ]
            }
            guard let d = try? JSONEncoder().encode(mapped),
                  let s = String(data: d, encoding: .utf8) else { return "{}" }
            return s
        }()
        return SettingsRecord(
            masterEnabled: (ud.object(forKey: "doomcoder.masterEnabled") as? Bool) ?? true,
            mode: SleepManager.shared.mode.rawValue,
            sessionTimerHrs: SleepManager.shared.sessionTimerHours,
            autoRevertSec: (ud.object(forKey: "doomcoder.session.autoRevertSeconds") as? Int) ?? 30,
            retentionDays: EventStore.retentionDays,
            screenOffRearmMin: SleepManager.shared.screenOffRearmMinutes,
            channelMacEnabled: channels.macNotification,
            channeliOSEnabled: channels.iOSCompanion,
            prefSessionStart: prefs.sessionStart,
            prefSessionEnd: prefs.sessionEnd,
            prefError: prefs.error,
            prefPermissionNeeded: prefs.permissionNeeded,
            prefAgentResponse: prefs.agentResponse,
            prefSubagentStart: prefs.subagentStart,
            prefSubagentEnd: prefs.subagentEnd,
            prefToolUse: prefs.toolUse,
            perAgentOverridesJSON: perAgentJSON,
            includePayloadSnippets: ud.bool(forKey: "doomcoder.privacy.includePayloadSnippets"),
            updatedAt: currentSettings?.updatedAt ?? [:],
            updatedBy: currentSettings?.updatedBy ?? macId
        )
    }

    // MARK: - Zone

    private func ensureZone() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        let op = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
        op.qualityOfService = .userInitiated
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.modifyRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    cont.resume()
                case .failure(let err):
                    if Self.isBenignAlreadyExistsError(err) { cont.resume() }
                    else { cont.resume(throwing: err) }
                }
            }
            database.add(op)
        }
    }

    // MARK: - Cache pre-warm

    private func fetchRecordByID(_ id: CKRecord.ID) async -> CKRecord? {
        await withCheckedContinuation { (cont: CheckedContinuation<CKRecord?, Never>) in
            let op = CKFetchRecordsOperation(recordIDs: [id])
            op.qualityOfService = .userInitiated
            var out: CKRecord?
            op.perRecordResultBlock = { _, result in
                if case .success(let record) = result { out = record }
            }
            op.fetchRecordsResultBlock = { _ in cont.resume(returning: out) }
            database.add(op)
        }
    }

    /// Best-effort fetch of the two stable records the Mac re-saves
    /// across launches (`MacStatus-{macId}` + `Settings-singleton`).
    /// Storing the fresh CKRecord into `serverRecords` ensures the first
    /// publish after launch carries a valid `recordChangeTag` and avoids
    /// the 14/2004 "record to insert already exists" noise on
    /// re-installs / new builds / account-switch flows. Missing records
    /// are normal on first-ever launch and silently ignored.
    private func prewarmStableRecordCache() async {
        let macStatusID = CKRecord.ID(recordName: "MacStatus-\(macId)", zoneID: zoneID)
        let settingsID  = CKRecord.ID(recordName: SettingsRecord.singletonRecordName, zoneID: zoneID)
        let fetched: [CKRecord] = await withCheckedContinuation { (cont: CheckedContinuation<[CKRecord], Never>) in
            let op = CKFetchRecordsOperation(recordIDs: [macStatusID, settingsID])
            op.qualityOfService = .userInitiated
            var out: [CKRecord] = []
            op.perRecordResultBlock = { _, result in
                if case .success(let r) = result { out.append(r) }
            }
            op.fetchRecordsResultBlock = { _ in cont.resume(returning: out) }
            database.add(op)
        }
        for record in fetched {
            serverRecords.store(record)
            // Also seed currentSettings from the server-known Settings so
            // the first publishSettingsField patches the right base.
            if record.recordType == CloudKitConstants.RecordType.settings,
               let s = SettingsRecord(record) {
                var local = localSettingsSnapshot()
                local.merge(with: s)
                currentSettings = local
                // Apply merged settings to SleepManager, TrackingStore, etc.
                // Without this, iOS changes written while Mac was offline are
                // silently merged into currentSettings but never pushed to the
                // actual Mac subsystems — the delta fetch won't re-deliver them
                // because the delta token is already past those writes.
                applyRemoteSettings(local)
            }
        }
        logger.info("prewarmStableRecordCache: fetched=\(fetched.count, privacy: .public)")
    }

    // MARK: - Subscriptions

    private func ensureSubscriptionsBestEffort() async {
        let dbSub = CKDatabaseSubscription(subscriptionID: "doomcoder-db-sub")
        let dbInfo = CKSubscription.NotificationInfo()
        dbInfo.shouldSendContentAvailable = true
        dbSub.notificationInfo = dbInfo

        let settingsPredicate = NSPredicate(format: "recordName == %@", SettingsRecord.singletonRecordName)
        let settingsSub = CKQuerySubscription(
            recordType: CloudKitConstants.RecordType.settings,
            predicate: settingsPredicate,
            subscriptionID: "doomcoder-settings-sub",
            options: [.firesOnRecordUpdate]
        )
        let settingsInfo = CKSubscription.NotificationInfo()
        settingsInfo.shouldSendContentAvailable = true
        settingsSub.notificationInfo = settingsInfo

        let op = CKModifySubscriptionsOperation(
            subscriptionsToSave: [dbSub, settingsSub],
            subscriptionIDsToDelete: nil
        )
        op.qualityOfService = .utility
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            op.modifySubscriptionsResultBlock = { [logger] result in
                switch result {
                case .success:
                    logger.info("ensureSubscriptions: db-sub + settings-sub OK")
                case .failure(let err):
                    if Self.isBenignAlreadyExistsError(err) {
                        logger.info("ensureSubscriptions: subs already exist")
                    } else {
                        logger.error("ensureSubscriptions failed (non-fatal): \(err.localizedDescription, privacy: .public)")
                    }
                }
                cont.resume()
            }
            database.add(op)
        }
    }

    // MARK: - Heartbeat (90 s — MacStatus only)

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let screenAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
                let appHidden    = NSApp?.isHidden ?? false
                if screenAsleep && appHidden { return }
                self.publishMacStatus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    // MARK: - Fetch safety-net (30 s)

    /// Adaptive backstop fetch timer.
    /// - 15 s when any Mac UI surface (Configure / Settings / menu panel) is
    ///   visible — the user expects iOS toggles to apply within seconds.
    /// - 30 s otherwise — preserves battery while keeping iOS edits bounded.
    /// Toggled at runtime via `setUIVisible(_:)` from window controllers.
    private var uiVisibleFastFetch = false
    private var fetchIntervalSeconds: TimeInterval { uiVisibleFastFetch ? 15 : 30 }

    /// Starts the backstop fetch timer at the current adaptive interval.
    /// Primary real-time path remains:
    ///   APNs silent push → didReceiveRemoteNotification → fetchChanges()
    /// This timer ensures iOS→Mac sync recovers even if push delivery fails.
    private func startFetchTimer() {
        fetchTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: fetchIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.fetchChanges() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fetchTimer = timer
    }

    /// UI surfaces (Configure window, status panel, etc.) call this when they
    /// appear / disappear so the backstop fetch interval tightens while the
    /// user can observe stale state.
    func setUIVisible(_ visible: Bool) {
        guard visible != uiVisibleFastFetch else { return }
        uiVisibleFastFetch = visible
        if fetchTimer != nil { startFetchTimer() }
        logger.info("setUIVisible(\(visible, privacy: .public)) — fetch interval=\(self.fetchIntervalSeconds, privacy: .public)s")
        if visible {
            Task { await fetchChanges() }
        }
    }

    // MARK: - Event pruning (daily)

    private func startPruneTimer() {
        pruneTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pruneOldCloudKitEvents() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    /// Deletes CloudKit Event records older than EventStore.retentionDays.
    /// Mirrors the SQLite pruning DoomCoder already does locally.
    func pruneOldCloudKitEvents() async {
        guard isAvailable else { return }
        let cutoff = Date(timeIntervalSinceNow: -Double(EventStore.retentionDays) * 86_400)
        let pred = NSPredicate(format: "ts < %@", cutoff as NSDate)
        let query = CKQuery(recordType: CloudKitConstants.RecordType.event, predicate: pred)
        do {
            let (matches, _) = try await database.records(matching: query, inZoneWith: zoneID,
                                                          desiredKeys: [], resultsLimit: 200)
            let ids = matches.compactMap { _, result in try? result.get().recordID }
            guard !ids.isEmpty else { return }
            let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: ids)
            op.qualityOfService = .background
            op.modifyRecordsResultBlock = { [logger] result in
                if case .success = result {
                    logger.info("pruneOldCloudKitEvents: deleted \(ids.count) events")
                }
            }
            database.add(op)
        } catch {
            logger.notice("pruneOldCloudKitEvents query failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Reauth

    private func scheduleReauth() {
        guard !reauthScheduled else { return }
        reauthScheduled = true
        isAvailable = false
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await MainActor.run { self?.reauthScheduled = false }
            await self?.refreshAccountStatus()
        }
    }

    // MARK: - Test ping

    // MARK: - Dev reset

    /// Development-only: deletes the DoomCoderZone from iCloud, clears all
    /// local engine state + subscription IDs + record caches, and re-runs
    /// bootstrap so a fresh CKSyncEngine + zone are created from scratch.
    /// Use to recover from a stuck CloudKit error flood (e.g. the 14/2004
    /// "record to insert already exists" loop). iOS will reseed its state
    /// on next launch (the .CKAccountChanged-equivalent zone-not-found
    /// recovery happens naturally on re-fetch).
    func devWipeCloudKitZone() async {
        logger.notice("devWipeCloudKitZone: starting")
        // 1) Pause heartbeats & in-flight pushes by flipping availability.
        isAvailable = false
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        fetchTimer?.invalidate();     fetchTimer = nil
        pruneTimer?.invalidate();     pruneTimer = nil
        syncEngine = nil
        regularRecordsByID.removeAll()
        settingsRecordsByID.removeAll()
        serverRecords.clear()
        pendingWrites = 0

        // 2) Delete the zone on the server (idempotent).
        let zone = CKRecordZone(zoneID: zoneID)
        let op = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: [zone.zoneID])
        op.qualityOfService = .userInitiated
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            op.modifyRecordZonesResultBlock = { [logger] result in
                switch result {
                case .success:
                    logger.notice("devWipeCloudKitZone: zone deleted")
                case .failure(let err):
                    logger.notice("devWipeCloudKitZone: delete returned \(err.localizedDescription, privacy: .public) (ignored)")
                }
                cont.resume()
            }
            database.add(op)
        }

        // 3) Clear all locally persisted engine + subscription state.
        UserDefaults.standard.removeObject(forKey: Self.engineStateKey)

        // 4) Delete known subscription IDs so ensureSubscriptionsBestEffort
        //    re-registers them against the new zone.
        let subsOp = CKModifySubscriptionsOperation(
            subscriptionsToSave: nil,
            subscriptionIDsToDelete: ["doomcoder-db-sub", "doomcoder-settings-sub"]
        )
        subsOp.qualityOfService = .utility
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            subsOp.modifySubscriptionsResultBlock = { _ in cont.resume() }
            database.add(subsOp)
        }

        // 5) Re-bootstrap from scratch.
        await bootstrap()
        logger.notice("devWipeCloudKitZone: re-bootstrap complete")
    }

    func sendTestPing() {
        logger.info("sendTestPing (isAvailable=\(self.isAvailable))")
        publishMacStatus()
        publishNotification(
            sessionKey: "test-\(UUID().uuidString.prefix(8))",
            agent: "claude", phase: "system", event: "test-ping",
            title: "DoomCoder Test Ping",
            body: "Manual ping from Configure → Settings.",
            channel: "iOSCompanion", success: true, ts: Date(),
            lastTool: nil, cwdBase: "~/"
        )
    }

    // MARK: - Helpers

    private nonisolated func sha256(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 1099511628211
        }
        return String(h, radix: 16)
    }

    private static func isBenignAlreadyExistsError(_ error: Error) -> Bool {
        guard let cke = error as? CKError else { return false }
        let benign: Set<CKError.Code> = [
            .serverRejectedRequest, .unknownItem, .invalidArguments, .serverRecordChanged
        ]
        if benign.contains(cke.code) { return true }
        if cke.code == .partialFailure,
           let perItem = cke.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            return perItem.values.allSatisfy { sub in
                guard let s = sub as? CKError else { return false }
                return benign.contains(s.code)
            }
        }
        return false
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudKitSyncEngine: CKSyncEngineDelegate {

    /// Extracts the CKRecord.ID from a PendingRecordZoneChange enum case.
    private nonisolated func id(from change: CKSyncEngine.PendingRecordZoneChange) -> CKRecord.ID? {
        switch change {
        case .saveRecord(let recordID):   return recordID
        case .deleteRecord(let recordID): return recordID
        @unknown default:                 return nil
        }
    }

    nonisolated func handleEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {
        switch event {

        case .stateUpdate(let e):
            if let data = try? JSONEncoder().encode(e.stateSerialization) {
                UserDefaults.standard.set(data, forKey: Self.engineStateKey)
            }

        case .accountChange(let e):
            await MainActor.run {
                switch e.changeType {
                case .signIn:
                    self.isAvailable = true
                case .signOut:
                    self.isAvailable = false
                    self.regularRecordsByID.removeAll()
                    self.settingsRecordsByID.removeAll()
                    self.pendingWrites = 0
                case .switchAccounts:
                    self.regularRecordsByID.removeAll()
                    self.settingsRecordsByID.removeAll()
                    self.pendingWrites = 0
                    Task { await self.refreshAccountStatus() }
                @unknown default:
                    break
                }
            }

        case .fetchedRecordZoneChanges(let e):
            for change in e.modifications {
                // Route through MainActor.run first so the CKRecord is in the
                // MainActor region before scheduleHandleFetched captures it in
                // the Task.detached closure — required by Swift 6 region checking.
                await MainActor.run { self.scheduleHandleFetched(change.record) }
            }
            await MainActor.run {
                self.lastSyncAt = Date()
                self.lastError = nil
            }

        case .sentRecordZoneChanges(let e):
            await MainActor.run {
                for saved in e.savedRecords {
                    self.regularRecordsByID.removeValue(forKey: saved.recordID)
                    if saved.recordType == CloudKitConstants.RecordType.settings {
                        self.settingsRecordsByID.removeValue(forKey: saved.recordID)
                        self.serverRecords.store(saved)
                    } else if saved.recordType == CloudKitConstants.RecordType.controlCommand {
                        // Refresh the cached server record so the next ack
                        // (if any) carries the freshest changeTag.
                        self.serverRecords.store(saved)
                        // Clear the in-flight ack tracker — ack succeeded.
                        self.pendingCommandAcks.removeValue(forKey: saved.recordID)
                    } else if saved.recordType == CloudKitConstants.RecordType.macStatus,
                              saved.recordID.recordName == "MacStatus-\(self.macId)" {
                        // Cache our own MacStatus tag for the next heartbeat.
                        self.serverRecords.store(saved)
                    } else if saved.recordType == CloudKitConstants.RecordType.session {
                        // Cache the Session tag so the next publishSession
                        // (toolCallCount/lastEvent/phase update) is an UPDATE,
                        // not an INSERT.
                        self.serverRecords.store(saved)
                    }
                }
                self.pendingWrites = self.regularRecordsByID.count + self.settingsRecordsByID.count
                if !e.savedRecords.isEmpty {
                    self.lastSyncAt = Date()
                    self.lastError  = nil
                }
            }
            for fail in e.failedRecordSaves {
                let errCode = fail.error.code
                if errCode == .serverRecordChanged {
                    // Recovery for the 14/2004 "record to insert already
                    // exists" flood: the engine retried a save without our
                    // recordChangeTag (e.g. after a crash that lost the
                    // in-memory cache, or because the record predates the
                    // persistent cache). Explicitly fetch the server record
                    // by ID so we re-acquire the tag, then re-enqueue (or
                    // drop, for one-shot inserts like ControlCommand acks).
                    let id = fail.record.recordID
                    let rtype = fail.record.recordType
                    self.logger.notice("save conflict on \(id.recordName, privacy: .public) (\(rtype, privacy: .public)) — recovering")
                    await self.recoverFromServerRecordChanged(id: id, recordType: rtype)
                }
                if errCode == .notAuthenticated {
                    await MainActor.run { self.scheduleReauth() }
                }
            }

        default:
            // Covers willSendChanges, didSendChanges, willFetchChanges,
            // fetchedDatabaseChanges, sentDatabaseChanges, and any future cases.
            break
        }
    }

    /// Provides records to CKSyncEngine.
    ///
    /// Canonical pattern (matching iOS CompanionSyncEngine): take ALL
    /// pending changes filtered only by `context.options.scope`, return a
    /// recordProvider closure that maps recordID → CKRecord (or nil if the
    /// record was dropped — CKSyncEngine then removes the change from its
    /// state instead of looping forever).
    ///
    /// Settings are sent first with the default save policy
    /// (`.ifServerRecordUnchanged`) so per-field LWW continues to work via
    /// `changedKeys` against the server changeTag carried in
    /// `settingsServerRecord`.
    ///
    /// All other record types (MacStatus heartbeat, Session, Event,
    /// NotificationLog, ControlCommand ack) ship with `savePolicy = .allKeys`
    /// so fresh records without a server changeTag don't get rejected as
    /// "record to insert already exists" (CKError 14/2004). ControlCommand
    /// acks separately keep the server changeTag via the
    /// `controlCommandServerRecords` cache.
    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        let (settingsSnap, regularSnap) = await MainActor.run {
            (self.settingsRecordsByID, self.regularRecordsByID)
        }

        // 1) Settings batch first. Default policy = .ifServerRecordUnchanged.
        let settingsPending = pending.filter { change in
            id(from: change).map { settingsSnap[$0] != nil } ?? false
        }
        if !settingsPending.isEmpty {
            return await CKSyncEngine.RecordZoneChangeBatch(
                pendingChanges: settingsPending,
                recordProvider: { id in settingsSnap[id] }
            )
        }

        // 2) Regular batch — provide records via recordProvider so any
        // pending changes whose record has been dropped from our local
        // cache return nil (CKSyncEngine then drops that change from its
        // state, preventing the orphan-pending-change retry loop).
        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pending,
            recordProvider: { id in regularSnap[id] }
        )
    }
}
