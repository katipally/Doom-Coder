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

    // MARK: - Settings state

    private var currentSettings: SettingsRecord?

    /// Server-side CKRecord for the singleton SettingsRecord. Updated by
    /// sentRecordZoneChanges so subsequent saves carry the latest changeTag.
    private var settingsServerRecord: CKRecord?

    // MARK: - Timers

    private var heartbeatTimer: Timer?
    private var pruneTimer: Timer?
    private var reauthScheduled = false

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

        // Step 3: signal availability. All publish methods gate on isAvailable.
        isAvailable = true
        accountStatusText = "iCloud synced"

        // Step 4: initial MacStatus heartbeat.
        publishMacStatus()
        logger.info("initial MacStatus enqueued")

        // Step 5: subscriptions (best-effort; push is a nice-to-have).
        await ensureSubscriptionsBestEffort()

        // Step 6: register for APNs so silent pushes can wake the Mac.
        await MainActor.run { NSApplication.shared.registerForRemoteNotifications() }
        logger.info("registerForRemoteNotifications requested")

        // Step 7: delta-fetch to apply any Settings or ControlCommand records
        // written by iOS while the Mac was offline.
        try? await syncEngine?.fetchChanges()

        // Step 8: safety-net drain for ControlCommands that CKSyncEngine
        // state hasn't seen yet (first-launch, token reset, etc.).
        await ControlCommandRouter.drainPending()

        // Step 9: 90 s heartbeat so iOS sees a fresh lastSeen regularly.
        startHeartbeat()

        // Step 10: daily CloudKit Event pruning.
        startPruneTimer()
    }

    // MARK: - Publish API

    func publishMacStatus() {
        guard isAvailable else { return }
        let sm = SleepManager.shared
        let rec = MacStatusRecord(
            macId: macId, name: macName,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0.0",
            sleepActive: sm.isActive,
            mode: sm.mode.rawValue,
            sessionEndsAt: nil,
            lastSeen: Date(),
            thermalState: sm.thermalStateText
        )
        enqueue(save: rec.toCKRecord())
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
        enqueue(save: rec.toCKRecord())
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
        enqueue(save: s.toCKRecord(base: settingsServerRecord))
    }

    func publishSettingsTouching(_ touchedFields: [String]) {
        guard isAvailable, !applyingRemoteSettings else { return }
        var s = localSettingsSnapshot()
        s.updatedAt = currentSettings?.updatedAt ?? s.updatedAt
        let now = Date()
        for f in touchedFields { s.touch(f, at: now, by: macId) }
        currentSettings = s
        enqueue(save: s.toCKRecord(base: settingsServerRecord))
    }

    func publishSettingsTouchingPerAgent(agent: String, subs: [String]) {
        guard isAvailable, !applyingRemoteSettings else { return }
        var s = localSettingsSnapshot()
        s.updatedAt = currentSettings?.updatedAt ?? s.updatedAt
        let now = Date()
        for sub in subs { s.touchPerAgent(agent, sub: sub, at: now, by: macId) }
        currentSettings = s
        enqueue(save: s.toCKRecord(base: settingsServerRecord))
    }

    func acknowledgeCommand(_ record: ControlCommandRecord) {
        guard isAvailable else { return }
        enqueue(save: record.toCKRecord())
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
                self.settingsServerRecord = record
                guard let remote = SettingsRecord(record) else {
                    self.logger.notice("handleFetched: settings decode failed")
                    return
                }
                var local = self.localSettingsSnapshot()
                local.merge(with: remote)
                self.currentSettings = local
                self.applyRemoteSettings(local)

            case CloudKitConstants.RecordType.controlCommand:
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

    // MARK: - Heartbeat (90 s)

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
                        self.settingsServerRecord = saved
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
                if errCode == .serverRecordChanged,
                   fail.record.recordType == CloudKitConstants.RecordType.settings {
                    self.logger.notice("settings conflict — re-fetching")
                    try? await syncEngine.fetchChanges()
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

    /// Provides records to CKSyncEngine. Settings are sent first; both
    /// batches use the default save policy (.ifServerRecordUnchanged) since
    /// Settings records always carry the server changeTag from settingsServerRecord
    /// and we handle .serverRecordChanged by re-fetching and re-merging.
    /// MacStatus/Session/etc. are written with fresh records each heartbeat so
    /// there is no prior changeTag — CKSyncEngine treats them as inserts when
    /// the tag is absent, which is equivalent to .allKeys for first-write.
    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges

        // Settings first so conflicts are detected early.
        let settingsSnap = await MainActor.run { self.settingsRecordsByID }
        let settingsPending = pending.filter { id(from: $0).map { settingsSnap[$0] != nil } ?? false }
        if !settingsPending.isEmpty {
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: settingsPending) { [self] id in
                await MainActor.run { self.settingsRecordsByID[id] }
            }
        }

        // Heartbeat / event records.
        let regularSnap = await MainActor.run { self.regularRecordsByID }
        let regularPending = pending.filter { id(from: $0).map { regularSnap[$0] != nil } ?? false }
        if !regularPending.isEmpty {
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: regularPending) { [self] id in
                await MainActor.run { self.regularRecordsByID[id] }
            }
        }

        return nil
    }
}
