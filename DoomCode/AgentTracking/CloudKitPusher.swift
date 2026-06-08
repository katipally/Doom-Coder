// CloudKitPusher.swift
//
// Mac-side push-only CKSyncEngine wrapper. Writes NotificationLog (one per
// dispatched notification), MacStatus (heartbeat singleton), AgentConfig
// (list of tracked agents singleton), AgentIcon (CKAssets for runtime icon
// delivery to iOS).
//
// Lessons baked in (from exp-ios-to-mac branch's hard-won fixes):
//   1. Persist `record.encodeSystemFields()` to disk for singletons
//      (MacStatus, AgentConfig, AgentIcon) — without this, CKError 14/2004
//      flood on relaunch.
//   2. Preflight singleton fetches before save to ensure server-known
//      recordChangeTag (handled by ServerRecordCache + post-save callback).
//   3. Re-entry guard on setupSyncEngine() — CKAccountChanged can fire mid
//      setup and tear down the in-flight engine.
//   4. ensureZone() BEFORE constructing CKSyncEngine — engine assumes the
//      zone exists.
//   5. Re-assert zone via engine.state.add(.saveZone) on restore.
//   6. Main-thread NotificationCenter posts from delegate callbacks.
//   7. didEnterBackground / willTerminate → force UserDefaults.synchronize.
//   8. NSWorkspace.didWakeNotification → trigger fetchChanges (just for
//      catching any stale state — we are mostly write-only here).
//   9. 5s safety-net timer (sendChanges keeps pending writes flowing) +
//      lifetime App-Nap opt-out so the timer fires reliably while idle.

import Foundation
import CloudKit
import AppKit
import IOKit
import OSLog
import DoomCodeCore

@MainActor
final class CloudKitPusher {

    static let shared = CloudKitPusher()

    private let logger = Logger(subsystem: "com.doomcoder", category: "ckpusher")
    let container: CKContainer
    let database: CKDatabase
    let zoneID: CKRecordZone.ID
    let serverRecords: ServerRecordCache

    private var engine: CKSyncEngine?
    private var delegate: CloudKitPusherDelegate?
    private var setupInProgress = false
    private var didSetup = false
    private var safetyTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    /// Lifetime App-Nap opt-out for the sync layer (see `start()`).
    private var appNapAssertion: NSObjectProtocol?

    /// Tracks every `Task.detached` engine kick (`sendChanges`/`fetchChanges`)
    /// so `stop()` can cancel them deterministically. Without this, a
    /// `Task.detached` outlives its call site and can race with the engine's
    /// teardown, producing spurious `cancel`-shaped errors on quit.
    /// `Set` is used (not array) so add/remove is O(1).
    private var pendingEngineTasks: Set<Task<Void, Never>> = []

    /// Stable identifier for this Mac, derived from IOPlatformUUID. Used as
    /// the `macId` field on every record we publish.
    let macId: String
    let macName: String

    /// Becomes true once the engine is constructed and the custom zone exists.
    private(set) var isReady = false

    private init() {
        self.container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
        self.database  = container.privateCloudDatabase
        let macId = Self.stableMacID()
        self.macId = macId
        // Per-Mac zone owned by this Mac. Shared zone-wide via a CKShare so
        // iPhones (same or different Apple ID) can join. Per-Mac naming avoids a
        // collision when two Macs share one Apple ID.
        self.zoneID    = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName(forMacId: macId),
                                         ownerName: CKCurrentUserDefaultName)
        self.serverRecords = ServerRecordCache(
            defaults: UserDefaults.standard,
            key: "doomcoder.ckpusher.serverRecords.v1"
        )
        self.macName = Host.current().localizedName ?? "Mac"
    }

    // MARK: - Lifecycle

    /// Start the pusher. Safe to call multiple times — internally guarded.
    func start() {
        // Keep the sync layer responsive even when keep-awake is Off. A menu-bar
        // (LSUIElement) app is App-Napped while idle, which throttles the poll
        // timer below to minutes — and APNs separately throttles content-available
        // pushes — so iOS→Mac commands could take minutes to land. Hold a lifetime
        // App-Nap opt-out so the poll + push handling stay prompt whenever the Mac
        // is awake. `.userInitiatedAllowingIdleSystemSleep` defeats App Nap but
        // does NOT disable system sleep — the Mac still sleeps normally (and
        // CloudKit can't reach a sleeping Mac regardless; commands apply on wake).
        // SleepManager's separate, stronger assertion (`.idleSystemSleepDisabled`)
        // still governs the actual keep-awake feature.
        if appNapAssertion == nil {
            appNapAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "DoomCode CloudKit sync responsiveness"
            )
        }

        Task { await setupSyncEngine() }

        // App lifecycle hooks (lessons #6, #7, #8, #9)
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            UserDefaults.standard.synchronize()
            // Cancel any in-flight engine tasks so we don't race with the
            // process tear-down (audit 2026-06 fix). The observer closure
            // is `Sendable` (NotificationCenter requires it), so we
            // hop to the main actor before touching the @MainActor-isolated
            // CloudKitPusher.
            Task { @MainActor in
                CloudKitPusher.shared.stop()
            }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            UserDefaults.standard.synchronize()
        }
        // Wake from sleep → flush pending writes AND fetch (pick up any
        // ControlCommand the iOS app wrote while we were asleep).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.kickEngine()
                self?.fetchNow()
                // Publish fresh status immediately so iOS sees the Mac is awake
                // rather than waiting up to 60 seconds for the next heartbeat.
                self?.publishMacStatus()
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.publishMacStatus()
                UserDefaults.standard.synchronize()
            }
        }
        // Foreground / activation → fetch promptly so remote commands land
        // quickly while the user is interacting with either device.
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fetchNow() }
        }
        nc.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.didSetup = false
                self.serverRecords.clear()
                await self.setupSyncEngine()
            }
        }

        // Safety-net flush + fetch — the reliable backstop for iOS→Mac commands
        // when silent push is throttled or undelivered.
        //
        // MUST be scheduled in `.common` run-loop modes. `Timer.scheduledTimer`
        // installs the timer in `.default` mode only, which is SUSPENDED while
        // the menu-bar panel/menus are open (the run loop switches to event
        // tracking). That stalled the only reliable fetch trigger exactly when
        // the user has the panel open watching for an update — the source of the
        // "iOS commands take forever to land while the Mac is visible" bug.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.kickEngine()
                self?.fetchNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }

    func kickEngine() {
        // Sends any pending state changes the engine has queued.
        // Called by the delegate (via a new Task) after applying a ControlCommand
        // so the MacStatus ack reaches iOS in <1s instead of up to 15s.
        //
        // MUST use Task.detached, NOT Task {}: CKSyncEngine guards re-entrancy
        // with a task-local marker set while a delegate callback runs. A plain
        // `Task {}` inherits task-local values, so when this is reached on a
        // path that originates inside a delegate callback the inherited marker
        // makes sendChanges() crash ("Cannot await a call into CKSyncEngine
        // from within a delegate callback"). Detaching escapes that scope.
        guard let engine else { return }
        let task = Task.detached { [weak self] in
            try? await engine.sendChanges()
            // Remove ourselves from the tracking set so the set does not
            // grow unbounded across many kicks. Hop back to the main actor
            // because `pendingEngineTasks` is `@MainActor`-isolated.
            await self?.removeEngineTaskFromSet()
        }
        pendingEngineTasks.insert(task)
    }

    /// Main-actor helper to remove the currently-executing task from the
    /// tracking set. Called from inside a `Task.detached` body after the
    /// engine work completes (success, failure, or cancellation).
    private func removeEngineTaskFromSet() async {
        // We cannot get a stable identity of the calling task from inside
        // its body, so we just clear all "finished" tasks by recreating
        // the set without the ones that have `isCancelled` set or have
        // already finished. Tasks in Swift Concurrency are `Hashable`;
        // we filter by checking `Task.isCancelled` on each.
        pendingEngineTasks = pendingEngineTasks.filter { !$0.isCancelled }
    }

    /// Cancels every tracked engine task. Called on `NSApplicationWillTerminate`
    /// to ensure no detached work outlives the process.
    func stop() {
        let inFlight = pendingEngineTasks
        pendingEngineTasks.removeAll()
        for t in inFlight { t.cancel() }
    }

    /// COMPLETE iCloud teardown for "Erase All Data". This Mac OWNS its private
    /// database, so deleting its custom zone(s) cascades away every record
    /// (MacStatus, AgentConfig, NotificationLog, AgentIcon, ControlCommand, every
    /// phone's CompanionStatus) AND the zone-wide CKShare. After this, iCloud
    /// holds no DoomCode data for this account and every paired iPhone goes empty
    /// on its next sync. Best-effort: if offline, the local wipe still proceeds
    /// and the caller relaunches.
    func eraseCloudKitData() async {
        stop()
        engine = nil

        // Only the app's own container is touched, so deleting EVERY custom zone
        // in the private DB is safe (covers stale zones from old macIds too).
        guard let status = try? await container.accountStatus(), status == .available else {
            logger.notice("ckpusher: eraseCloudKitData skipped server ops (account not available)")
            return
        }

        _ = try? await database.deleteSubscription(withID: "mac-zone-push-v1")

        if let zones = try? await database.allRecordZones() {
            let ids = zones.map(\.zoneID)
                .filter { $0.zoneName != CKRecordZone.ID.defaultZoneName }
            if !ids.isEmpty {
                _ = try? await database.modifyRecordZones(saving: [], deleting: ids)
                logger.notice("ckpusher: eraseCloudKitData deleted \(ids.count, privacy: .public) zone(s) from iCloud")
            }
        }
        serverRecords.clear()
    }

    private var lastTouchAt: Date = .distantPast

    /// Re-stamps `MacStatus.lastSeen` whenever we have proof the Mac is actively
    /// reaching CloudKit (a successful fetch / poll / command-apply). This keeps
    /// the iOS "last seen" honest: the "not reachable" banner used to fire purely
    /// off the 60s heartbeat, so a throttled status write made iOS show the Mac
    /// as offline even while it was applying commands. Debounced to one write
    /// per 25s unless forced.
    ///
    /// IMPORTANT: this only *queues* a pending record-zone change (the same
    /// thing `publishMacStatus` does). It must NOT call `kickEngine()` /
    /// `sendChanges()`, because `touchLastSeen` runs from inside the
    /// `CKSyncEngine` fetch delegate callback — awaiting back into the engine
    /// from a delegate callback is a fatal CloudKit misuse. `automaticallySync`
    /// plus the 5s safety timer flush the queued change for us.
    func touchLastSeen(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastTouchAt) < 25 { return }
        lastTouchAt = now
        publishMacStatus()
    }

    private func setupSyncEngine() async {
        // Lesson #3: re-entry guard
        guard !setupInProgress, !didSetup else { return }
        setupInProgress = true
        defer { setupInProgress = false }

        // Verify iCloud account is available before doing anything
        do {
            let status = try await container.accountStatus()
            guard status == .available else {
                logger.notice("ckpusher: iCloud account not available (\(String(describing: status), privacy: .public)); skipping setup")
                return
            }
        } catch {
            logger.error("ckpusher: accountStatus failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Lesson #4: ensure custom zone exists BEFORE constructing the engine
        if !(await ensureZone()) {
            logger.error("ckpusher: ensureZone failed")
            return
        }

        // ── Environment migration guard ──────────────────────────────────
        // v2.4.3 used the Development CloudKit environment (no explicit
        // icloud-container-environment entitlement). v2.4.4 adds Production.
        // Any CKSyncEngine state serialisation and ServerRecordCache blobs
        // written under Development are incompatible with Production (different
        // server-side record-change tags, sync tokens, etc.).
        // On the first launch in Production we wipe both so the engine starts
        // fresh: records are saved without a stale base changeTag, meaning
        // CloudKit creates them from scratch in the Production database.
        let environmentKey = "doomcoder.ckpusher.environment.v1"
        let currentEnv = "production"
        if UserDefaults.standard.string(forKey: environmentKey) != currentEnv {
            logger.notice("ckpusher: environment changed → wiping stale engine state and server-record cache")
            serverRecords.clear()
            UserDefaults.standard.removeObject(forKey: "doomcoder.ckpusher.engineState.v1")
            UserDefaults.standard.set(currentEnv, forKey: environmentKey)
        }

        // ── v3 shared-zone migration (one-shot) ──────────────────────────
        // The zone moved from the single "DoomCoderZone" to a per-Mac
        // "DoomCoderZone-<macId>". Old engine state / server records reference
        // the defunct zone, so wipe them once so the engine recreates the new
        // zone and re-uploads cleanly.
        let v3Key = "doomcoder.ckpusher.v3.zoneMigration"
        if !UserDefaults.standard.bool(forKey: v3Key) {
            logger.notice("ckpusher: v3 zone migration → wiping pre-v3 engine state + server cache")
            serverRecords.clear()
            UserDefaults.standard.removeObject(forKey: "doomcoder.ckpusher.engineState.v1")
            UserDefaults.standard.set(true, forKey: v3Key)
        }

        // ── Local-state reset generation (server-reset recovery) ──────────
        // The persisted CKSyncEngine state + ServerRecordCache hold change tokens,
        // recordChangeTags, and PENDING record-zone changes. After a CloudKit
        // "Reset Development Environment" (or any server-side wipe) these go
        // stale: the engine keeps retrying writes into a deleted zone
        // ("Zone Not Found" 26/2036) or with a tag for a deleted record
        // ("Unknown Item" 11/2003) — and may even retry a pending change that
        // targets the OLD single "DoomCoderZone". Reinstalling the Mac app does
        // NOT clear this (it lives in ~/Library/Preferences). Bumping this
        // generation forces ONE clean local wipe so the engine starts from zero,
        // recreates the per-Mac zone, and re-inserts every record fresh.
        let resetGenKey = "doomcoder.ckpusher.localResetGeneration"
        let currentResetGen = 2
        if UserDefaults.standard.integer(forKey: resetGenKey) != currentResetGen {
            logger.notice("ckpusher: local-state reset gen \(currentResetGen, privacy: .public) → wiping engine state + server cache for a clean re-sync")
            serverRecords.clear()
            UserDefaults.standard.removeObject(forKey: "doomcoder.ckpusher.engineState.v1")
            UserDefaults.standard.set(currentResetGen, forKey: resetGenKey)
        }

        let stateKey = "doomcoder.ckpusher.engineState.v1"
        let state: CKSyncEngine.State.Serialization?
        if let data = UserDefaults.standard.data(forKey: stateKey),
           let s = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data) {
            state = s
        } else {
            state = nil
        }
        let delegate = CloudKitPusherDelegate(pusher: self, stateKey: stateKey)
        self.delegate = delegate

        var config = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: state,
            delegate: delegate
        )
        config.automaticallySync = true
        let engine = CKSyncEngine(config)

        // Lesson #5: re-assert zone on restore
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        self.engine = engine
        self.didSetup = true
        self.isReady = true

        logger.notice("ckpusher: ready (macId=\(self.macId, privacy: .public), zone=\(CloudKitConstants.zoneName(forMacId: self.macId), privacy: .public))")
        NotificationCenter.default.post(name: .cloudKitPusherReady, object: nil)

        // Pull any ControlCommand records written by iOS before we launched.
        // Called BEFORE zone subscription so the initial fetch is never delayed
        // by a slow CloudKit subscription response.
        fetchNow()

        // Subscribe to zone changes so iOS ControlCommands trigger a silent
        // APNs push to this Mac — reducing worst-case latency from 15s to <3s.
        // Fire-and-forget: a slow or failing subscription never blocks the fetch.
        Task { await self.ensureZoneSubscription() }
    }

    private func ensureZoneSubscription() async {
        let subID = "mac-zone-push-v1"
        let sub = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: subID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent push — no visible alert or badge
        sub.notificationInfo = info
        do {
            try await database.save(sub)
            logger.notice("ckpusher: zone subscription saved (id=\(subID, privacy: .public))")
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            logger.notice("ckpusher: zone subscription already exists (\(subID, privacy: .public))")
        } catch let e as CKError where e.code == .permissionFailure {
            logger.error("ckpusher: zone subscription permission failure — check aps-environment entitlement")
        } catch {
            logger.error("ckpusher: zone subscription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureZone() async -> Bool {
        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            return true
        } catch let error as CKError where error.code == .serverRecordChanged {
            return true
        } catch let error as CKError where error.code == .zoneNotFound {
            // Try again — modifyRecordZones with saving should create it.
            do {
                _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
                return true
            } catch {
                logger.error("ckpusher: ensureZone retry failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        } catch {
            logger.error("ckpusher: ensureZone failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Publish API

    /// Emit a NotificationLog for an outbound notification. Pure INSERT —
    /// no recordChangeTag handling needed because each notif has a unique
    /// notifId.
    func publishNotificationLog(_ rec: NotificationLogRecord) {
        guard let engine else {
            logger.notice("ckpusher: not ready, dropping notif \(rec.notifId, privacy: .public)")
            return
        }
        let id = rec.recordID(in: zoneID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        pendingNotificationLogs[id.recordName] = rec
    }

    /// Heartbeat / status singleton. Called every 60s + on sleep/wake + on any
    /// SleepManager state change. Reflects the LIVE keep-awake state so iOS can
    /// mirror it and confirm remote commands via the ack fields.
    func publishMacStatus(sleepActive: Bool? = nil) {
        guard let engine else { return }
        let sm = SleepManager.shared
        let ud = UserDefaults.standard

        // Encode per-agent status lines for iOS expandable detail view.
        // Explicit if-else (not ternary + closure) for Swift 6 concurrency clarity.
        var agentJSON: String? = nil
        if sm.keepAwakeMode == .auto {
            let lines: [[String: Any]] = sm.autoStatusLines.map { l in
                ["name": l.agentDisplayName, "raw": l.agentRaw, "key": l.id,
                 "state": l.state, "type": l.agentType,
                 "idleSecs": l.idleSecs, "pidAlive": l.pidAlive]
            }
            if let data = try? JSONSerialization.data(withJSONObject: lines) {
                agentJSON = String(data: data, encoding: .utf8)
            }
        }

        let rec = MacStatusRecord(
            macId: macId,
            name: macName,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            sleepActive: sleepActive ?? sm.isActive,
            mode: sm.mode.rawValue,
            lastSeen: Date(),
            thermalState: sm.thermalStateText,
            keepAwakeMode: sm.keepAwakeMode.rawValue,
            activeAgentCount: sm.activeAgentCount,
            sessionTimerHours: sm.sessionTimerHours,
            elapsedSeconds: sm.elapsedSeconds,
            lastAppliedCommandId: ud.string(forKey: Self.lastAppliedCommandIdKey),
            lastAppliedAt: ud.object(forKey: Self.lastAppliedAtKey) as? Date,
            masterEnabled: ud.object(forKey: CloudKitPusherDelegate.masterEnabledKey) as? Bool ?? true,
            agentStatusJSON: agentJSON,
            autoGraceEndsAt: nil,
            // v2.6 — auto-mode redesign fields. Always populated for iOS to
            // mirror the Mac's compact status pill.
            autoSignal: sm.keepAwakeMode == .auto ? sm.dominantAutoSignal.rawValue : nil,
            isUserActive: sm.keepAwakeMode == .auto ? sm.isUserActive : nil,
            isSnoozed: sm.isSnoozed,
            snoozeUntil: sm.snoozeUntil,
            snoozeDuration: sm.snoozeDuration?.rawValue
        )
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(rec.recordID(in: zoneID))])
        pendingMacStatus = rec
    }

    /// UserDefaults keys for the remote-command ack channel (written by the
    /// delegate when a ControlCommand is applied, read here when publishing).
    static let lastAppliedCommandIdKey = "doomcoder.ckpusher.lastAppliedCommandId"
    static let lastAppliedAtKey        = "doomcoder.ckpusher.lastAppliedAt"

    /// Pull zone changes now. Used to pick up iOS-written ControlCommand
    /// records promptly (launch, foreground, wake, and the safety timer).
    func fetchNow() {
        // Task.detached (not Task {}): see kickEngine() — a plain Task inherits
        // the CKSyncEngine delegate-callback task-local marker and would crash
        // if fetchNow() is ever reached from a delegate-originated context.
        guard let engine else { return }
        let task = Task.detached { [weak self] in
            try? await engine.fetchChanges()
            await self?.removeEngineTaskFromSet()
        }
        pendingEngineTasks.insert(task)
    }

    /// Publish the list of tracked agents on this Mac plus installed-state
    /// and per-agent status text. Called on launch and whenever the user
    /// toggles agents in Tracking pane, installs/uninstalls an agent, or on
    /// the 60s heartbeat.
    func publishAgentConfig(agents: [TrackedAgent],
                            installed: [TrackedAgent] = [],
                            statuses: [TrackedAgent: String] = [:]) {
        guard let engine else { return }
        var statusDict: [String: String] = [:]
        for (k, v) in statuses { statusDict[k.rawValue] = v }
        let statusesJSON: String = {
            guard !statusDict.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: statusDict),
                  let str  = String(data: data, encoding: .utf8) else { return "" }
            return str
        }()
        // Per-agent "what you'll be notified about" rows the user has enabled,
        // rendered here (Mac owns the copy) and synced read-only to iOS.
        var deliverables: [String: [AgentDeliverable]] = [:]
        for agent in agents {
            let prefs = AgentNotificationStore.prefs(for: agent)
            let rows = prefs.enabledCategories(for: agent).map { id -> AgentDeliverable in
                let meta = AgentNotificationCatalog.meta(id)
                return AgentDeliverable(title: meta.title, symbol: meta.symbol, detail: meta.detail)
            }
            if !rows.isEmpty { deliverables[agent.rawValue] = rows }
        }
        let rec = AgentConfigRecord(
            macId: macId,
            agents: agents.map(\.rawValue),
            installedAgents: installed.map(\.rawValue),
            statuses: statusesJSON,
            deliverables: AgentConfigRecord.agentDeliverablesJSON(from: deliverables),
            updatedAt: Date()
        )
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(rec.recordID(in: zoneID))])
        pendingAgentConfig = rec
    }

    /// Publish an AgentIcon CKAsset record. `pngFileURL` must point at a
    /// stable file path that survives until the upload completes.
    func publishAgentIcon(agent: TrackedAgent, pngFileURL: URL, pngSHA256: String) {
        guard let engine else { return }
        let rec = AgentIconRecord(agent: agent.rawValue, pngSHA256: pngSHA256)
        let id = AgentIconRecord.recordID(for: agent.rawValue, in: zoneID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        pendingAgentIcons[id.recordName] = (rec, pngFileURL)
    }

    /// Delete a notification log record (used by reaper).
    func deleteNotificationLogs(recordIDs: [CKRecord.ID]) {
        guard let engine else { return }
        engine.state.add(pendingRecordZoneChanges: recordIDs.map { .deleteRecord($0) })
    }

    /// Deletes a companion device's `CompanionStatusRecord` from CloudKit (used
    /// by "Forget device"). The record lives in this Mac's private DB zone, so
    /// the sync engine can remove it; a still-alive device simply re-registers.
    func deleteCompanionStatus(deviceId: String) {
        guard let engine else { return }
        let id = CKRecord.ID(recordName: "CompanionStatus-\(deviceId)", zoneID: zoneID)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(id)])
        kickEngine()
    }

    // MARK: - In-flight payloads (read by delegate)

    var pendingNotificationLogs: [String: NotificationLogRecord] = [:]
    var pendingMacStatus: MacStatusRecord?
    var pendingAgentConfig: AgentConfigRecord?
    var pendingAgentIcons: [String: (AgentIconRecord, URL)] = [:]

    /// Called by the delegate to build the CKRecord for a queued save.
    /// Lesson #1 + #2 — singletons re-use the cached server CKRecord so the
    /// recordChangeTag is preserved.
    func buildRecord(for recordID: CKRecord.ID) -> CKRecord? {
        switch recordID.recordName {
        case let name where name.hasPrefix("NotificationLog-"):
            return pendingNotificationLogs[name]?.toCKRecord(in: zoneID)
        case let name where name.hasPrefix("MacStatus-"):
            guard let rec = pendingMacStatus else { return nil }
            return rec.toCKRecord(in: zoneID, base: serverRecords.record(forName: name))
        case let name where name.hasPrefix("AgentConfig-"):
            guard let rec = pendingAgentConfig else { return nil }
            return rec.toCKRecord(in: zoneID, base: serverRecords.record(forName: name))
        case let name where name.hasPrefix("AgentIcon-"):
            guard let (rec, url) = pendingAgentIcons[name] else { return nil }
            let r = rec.toCKRecord(in: zoneID, pngFileURL: url)
            // Preserve recordChangeTag if known
            if let base = serverRecords.record(forName: name) {
                // copy system fields by mutating base's fields with new values
                for key in r.allKeys() { base[key] = r[key] }
                return base
            }
            return r
        default:
            return nil
        }
    }

    func clearPending(for recordID: CKRecord.ID) {
        let name = recordID.recordName
        pendingNotificationLogs.removeValue(forKey: name)
        if name.hasPrefix("MacStatus-")   { pendingMacStatus = nil }
        if name.hasPrefix("AgentConfig-") { pendingAgentConfig = nil }
        pendingAgentIcons.removeValue(forKey: name)
    }

    // MARK: - Failure recovery (server-reset / stale-tag self-heal)

    /// A save failed with `.unknownItem` (11/2003 "recordChangeTag specified,
    /// but record not found") — our cached base tag points at a record the
    /// server no longer has (e.g. after a CloudKit dev-environment reset). Drop
    /// the stale base so the next send is a fresh INSERT, then re-queue.
    func recoverUnknownItem(_ recordID: CKRecord.ID) {
        guard recordID.zoneID == zoneID, let engine else { return }
        serverRecords.remove(id: recordID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    /// A save failed with `.zoneNotFound` / `.userDeletedZone` (26/2036) — our
    /// per-Mac zone is gone. Re-assert ONLY our own zone (never a stale legacy
    /// zone a leftover pending change might reference), drop the stale base, and
    /// re-queue the record so it re-inserts once the zone is recreated.
    func recoverZoneNotFound(_ recordID: CKRecord.ID) {
        guard let engine else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        guard recordID.zoneID == zoneID else { return }
        serverRecords.remove(id: recordID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    // MARK: - macId

    /// Returns a stable per-Mac identifier derived from IOPlatformUUID.
    private static func stableMacID() -> String {
        let key = "doomcoder.ckpusher.macId.v1"
        if let cached = UserDefaults.standard.string(forKey: key), !cached.isEmpty {
            return cached
        }
        // IOPlatformUUID via IOKit
        let entry = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IOServiceMatching("IOPlatformExpertDevice"))
        defer { if entry != 0 { IOObjectRelease(entry) } }
        if entry != 0,
           let cfStr = IORegistryEntryCreateCFProperty(entry,
                                                       kIOPlatformUUIDKey as CFString,
                                                       kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
            UserDefaults.standard.set(cfStr, forKey: key)
            return cfStr
        }
        // Fallback: random UUID, persisted
        let uuid = UUID().uuidString
        UserDefaults.standard.set(uuid, forKey: key)
        return uuid
    }
}

extension Notification.Name {
    /// Posted on main thread once the CKSyncEngine is constructed and the
    /// zone exists. Subscribers may begin calling publish* methods.
    static let cloudKitPusherReady = Notification.Name("doomcoder.ckpusher.ready")
}

// MARK: - CKShare coordinator (Mac = owner)
//
// The Mac owns its per-Mac zone and shares it ZONE-WIDE via a single
// `CKShare(recordZoneID:)`. Every iPhone — same OR different Apple ID — accepts
// that share and syncs through its `sharedCloudDatabase`. Share management
// (create / fetch / participant list / revoke) uses direct database operations,
// which is the supported path for shares (the sync engine handles record data,
// not share lifecycle).

/// A device that has accepted this Mac's share, surfaced for the Connections UI.
struct ShareParticipantInfo: Identifiable, Sendable {
    let id: String            // participant userRecordID name (stable)
    let displayName: String   // account name, or "Participant"
    let email: String?
    let isCurrentUser: Bool   // a same-Apple-ID participant (owner's own devices)
    let acceptanceStatus: String  // "Accepted" | "Pending" | "Removed"
}

@MainActor
@Observable
final class MacShareCoordinator {
    static let shared = MacShareCoordinator()

    /// The active zone-wide share, once created/fetched.
    private(set) var share: CKShare?
    /// The share URL to encode in a QR / copy as a link. Nil until ready.
    private(set) var shareURL: URL?
    /// Participants who have accepted (or are pending), for the device list.
    private(set) var participants: [ShareParticipantInfo] = []
    /// Last user-facing error (e.g. account unavailable), or nil.
    private(set) var lastError: String?
    /// True while a create/fetch is in flight (drives the UI spinner).
    private(set) var isWorking = false

    private var container: CKContainer { CloudKitPusher.shared.container }
    private var database: CKDatabase { CloudKitPusher.shared.database }
    private var zoneID: CKRecordZone.ID { CloudKitPusher.shared.zoneID }

    private init() {}

    /// Ensures a zone-wide share exists for this Mac's zone, creating it on first
    /// use. Idempotent — subsequent calls fetch the existing share. Safe to call
    /// whenever the Add-Device sheet is opened.
    func ensureShare() async {
        guard CloudKitPusher.shared.isReady else {
            lastError = "iCloud isn't ready yet. Try again in a moment."
            return
        }
        isWorking = true
        defer { isWorking = false }
        lastError = nil

        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        // Fast path: a share already exists for this zone.
        if let existing = try? await database.record(for: shareID) as? CKShare {
            apply(existing)
            return
        }
        // Create a new zone-wide share with read-write public permission so any
        // device that scans the QR / opens the link can join AND write (control
        // commands, its own presence). The link is therefore a secret; the user
        // can revoke participants from the Connections list.
        let newShare = CKShare(recordZoneID: zoneID)
        newShare.publicPermission = .readWrite
        newShare[CKShare.SystemFieldKey.title] =
            "Doom Code — \(CloudKitPusher.shared.macName)" as CKRecordValue
        do {
            let result = try await database.modifyRecords(saving: [newShare], deleting: [])
            for (_, saveResult) in result.saveResults {
                if case .success(let rec) = saveResult, let s = rec as? CKShare {
                    apply(s)
                    return
                }
            }
            // Some accounts return the share via a follow-up fetch.
            if let fetched = try? await database.record(for: shareID) as? CKShare {
                apply(fetched)
            } else {
                lastError = "Couldn't create the share. Check your iCloud sign-in."
            }
        } catch let e as CKError where e.code == .serverRecordChanged {
            // Lost a create race — fetch the winner.
            if let fetched = try? await database.record(for: shareID) as? CKShare {
                apply(fetched)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Re-fetches the share to refresh the participant list (after someone joins
    /// or is removed).
    func refresh() async {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let s = try? await database.record(for: shareID) as? CKShare {
            apply(s)
        }
    }

    /// Revokes a participant (the user tapped "Remove" on a device row).
    func removeParticipant(id: String) async {
        guard let share else { return }
        guard let participant = share.participants.first(where: {
            $0.userIdentity.userRecordID?.recordName == id
        }) else { return }
        share.removeParticipant(participant)
        do {
            _ = try await database.modifyRecords(saving: [share], deleting: [])
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func apply(_ s: CKShare) {
        self.share = s
        self.shareURL = s.url
        self.participants = s.participants.compactMap { p in
            // Skip the owner (this Mac) in the device list.
            guard p.role != .owner else { return nil }
            let identity = p.userIdentity
            let recName = identity.userRecordID?.recordName ?? UUID().uuidString
            let name = identity.nameComponents
                .map { PersonNameComponentsFormatter().string(from: $0) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? "Participant"
            let email = identity.lookupInfo?.emailAddress
            let status: String
            switch p.acceptanceStatus {
            case .accepted: status = "Accepted"
            case .pending:  status = "Pending"
            case .removed:  status = "Removed"
            default:        status = "Unknown"
            }
            return ShareParticipantInfo(
                id: recName,
                displayName: name,
                email: email,
                isCurrentUser: identity.userRecordID?.recordName == CKCurrentUserDefaultName,
                acceptanceStatus: status
            )
        }
    }
}
