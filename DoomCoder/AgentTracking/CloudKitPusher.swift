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
//   9. 30s safety-net timer (sendChanges keeps pending writes flowing).

import Foundation
import CloudKit
import AppKit
import IOKit
import OSLog
import DoomCoderCore

@MainActor
final class CloudKitPusher {

    static let shared = CloudKitPusher()

    private let logger = Logger(subsystem: "com.doomcoder", category: "ckpusher")
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    let serverRecords: ServerRecordCache

    private var engine: CKSyncEngine?
    private var delegate: CloudKitPusherDelegate?
    private var setupInProgress = false
    private var didSetup = false
    private var safetyTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    /// Stable identifier for this Mac, derived from IOPlatformUUID. Used as
    /// the `macId` field on every record we publish.
    let macId: String
    let macName: String

    /// Becomes true once the engine is constructed and the custom zone exists.
    private(set) var isReady = false

    private init() {
        self.container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
        self.database  = container.privateCloudDatabase
        self.zoneID    = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName,
                                         ownerName: CKCurrentUserDefaultName)
        self.serverRecords = ServerRecordCache(
            defaults: UserDefaults.standard,
            key: "doomcoder.ckpusher.serverRecords.v1"
        )
        self.macId = Self.stableMacID()
        self.macName = Host.current().localizedName ?? "Mac"
    }

    // MARK: - Lifecycle

    /// Start the pusher. Safe to call multiple times — internally guarded.
    func start() {
        Task { await setupSyncEngine() }

        // App lifecycle hooks (lessons #6, #7, #8, #9)
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            UserDefaults.standard.synchronize()
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

        // Safety-net 30s flush + fetch (so iOS ControlCommands land within 30s
        // even if no push arrives).
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.kickEngine()
                self?.fetchNow()
            }
        }
    }

    private func kickEngine() {
        // Sends any pending state changes the engine has queued.
        guard let engine else { return }
        Task { try? await engine.sendChanges() }
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
    /// plus the 30s safety timer flush the queued change for us.
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

        // Ensure the iOS-facing subscription on this database (so iOS users
        // who haven't run their app yet aren't blocked — but in practice the
        // iOS app registers its own subscriptions).
        // We don't register iOS-side subscriptions from Mac.

        logger.notice("ckpusher: ready (macId=\(self.macId, privacy: .public), zone=\(CloudKitConstants.zoneName, privacy: .public))")
        NotificationCenter.default.post(name: .cloudKitPusherReady, object: nil)
        // Pull any ControlCommand records written by iOS before we launched.
        fetchNow()
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
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(rec.recordID)])
        pendingNotificationLogs[rec.recordID.recordName] = rec
    }

    /// Heartbeat / status singleton. Called every 60s + on sleep/wake + on any
    /// SleepManager state change. Reflects the LIVE keep-awake state so iOS can
    /// mirror it and confirm remote commands via the ack fields.
    func publishMacStatus(sleepActive: Bool? = nil) {
        guard let engine else { return }
        let sm = SleepManager.shared
        let ud = UserDefaults.standard
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
            masterEnabled: ud.object(forKey: CloudKitPusherDelegate.masterEnabledKey) as? Bool ?? true
        )
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(rec.recordID)])
        pendingMacStatus = rec
    }

    /// UserDefaults keys for the remote-command ack channel (written by the
    /// delegate when a ControlCommand is applied, read here when publishing).
    static let lastAppliedCommandIdKey = "doomcoder.ckpusher.lastAppliedCommandId"
    static let lastAppliedAtKey        = "doomcoder.ckpusher.lastAppliedAt"

    /// Pull zone changes now. Used to pick up iOS-written ControlCommand
    /// records promptly (launch, foreground, wake, and the safety timer).
    func fetchNow() {
        guard let engine else { return }
        Task { try? await engine.fetchChanges() }
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
        let rec = AgentConfigRecord(
            macId: macId,
            agents: agents.map(\.rawValue),
            installedAgents: installed.map(\.rawValue),
            statuses: statusesJSON,
            updatedAt: Date()
        )
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(rec.recordID)])
        pendingAgentConfig = rec
    }

    /// Publish an AgentIcon CKAsset record. `pngFileURL` must point at a
    /// stable file path that survives until the upload completes.
    func publishAgentIcon(agent: TrackedAgent, pngFileURL: URL, pngSHA256: String) {
        guard let engine else { return }
        let rec = AgentIconRecord(agent: agent.rawValue, pngSHA256: pngSHA256)
        let id = AgentIconRecord.recordID(for: agent.rawValue)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        pendingAgentIcons[id.recordName] = (rec, pngFileURL)
    }

    /// Delete a notification log record (used by reaper).
    func deleteNotificationLogs(recordIDs: [CKRecord.ID]) {
        guard let engine else { return }
        engine.state.add(pendingRecordZoneChanges: recordIDs.map { .deleteRecord($0) })
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
            return pendingNotificationLogs[name]?.toCKRecord()
        case let name where name.hasPrefix("MacStatus-"):
            guard let rec = pendingMacStatus else { return nil }
            return rec.toCKRecord(base: serverRecords.record(forName: name))
        case let name where name.hasPrefix("AgentConfig-"):
            guard let rec = pendingAgentConfig else { return nil }
            return rec.toCKRecord(base: serverRecords.record(forName: name))
        case let name where name.hasPrefix("AgentIcon-"):
            guard let (rec, url) = pendingAgentIcons[name] else { return nil }
            let r = rec.toCKRecord(pngFileURL: url)
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
