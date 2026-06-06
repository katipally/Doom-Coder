// CloudKitPusher.swift
//
// Mac-side push-only CKSyncEngine wrapper. Writes NotificationLog (one per
// dispatched notification), the Mac's own DeviceRecord(role: .mac) (heartbeat
// presence singleton, v7 — replaces MacStatus), AgentConfig (list of tracked
// agents singleton), AgentIcon (CKAssets for runtime icon delivery to iOS).
// READS peer DeviceRecord(role: .ios) out of the zone into the unified device
// store; connection state is DERIVED (DerivedDeviceState), not tracked.
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
import Combine
import DoomCoderCore

@MainActor
final class CloudKitPusher: ObservableObject {

    static let shared = CloudKitPusher()

    private let logger = Logger(subsystem: "com.doomcoder", category: "ckpusher")
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    let serverRecords: ServerRecordCache

    fileprivate(set) var engine: CKSyncEngine?
    private var delegate: CloudKitPusherDelegate?
    private var setupInProgress = false
    private var didSetup = false
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
        // v5.2: Return to foreground → fetch. CKSyncEngine
        // already reacts to .didBecomeActive via the system
        // (iOS / macOS) but it can be delayed 1–3s after the
        // app visually appears. Calling fetchChanges() here
        // closes the gap the user sees in the Connections
        // tab on alt-tab back to the panel.
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.kickEngine()
                self?.fetchNow()
            }
        }
        // Wake from sleep → flush pending writes AND fetch.
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
        // Foreground / activation → fetch promptly so any new Mac state
        // surfaces quickly while the user is interacting with the app.
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

        // v6: NO polling timer. Sync is event-driven — silent push, app
        // foreground (didBecomeActive), wake-from-sleep, account change, and
        // the manual refresh button all trigger a fetch. The old 10s safety
        // timer is what made the panel feel laggy; with the release
        // aps-environment fix, push is now actually delivered.
    }

    func kickEngine() {
        // Sends any pending state changes the engine has queued.
        //
        // MUST use Task.detached, NOT Task {}: CKSyncEngine guards re-entrancy
        // with a task-local marker set while a delegate callback runs. A plain
        // `Task {}` inherits task-local values, so when this is reached on a
        // path that originates inside a delegate callback the inherited marker
        // makes sendChanges() crash ("Cannot await a call into CKSyncEngine
        // from within a delegate callback"). Detaching escapes that scope.
        guard let engine else { return }
        Task.detached { try? await engine.sendChanges() }
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

        logger.notice("ckpusher: ready (macId=\(self.macId, privacy: .public), zone=\(CloudKitConstants.zoneName, privacy: .public))")
        NotificationCenter.default.post(name: .cloudKitPusherReady, object: nil)

        // Pull any records written before we launched.
        // Called BEFORE zone subscription so the initial fetch is never delayed
        // by a slow CloudKit subscription response.
        fetchNow()

        // Subscribe to zone changes so any new record triggers a silent
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
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(rec.recordID)])
        pendingNotificationLogs[rec.recordID.recordName] = rec
    }

    /// Heartbeat / presence record. Called every 60s + on sleep/wake + on any
    /// SleepManager state change. Reflects the LIVE keep-awake state so iOS can
    /// see at a glance whether the Mac is awake.
    ///
    /// v7: publishes THIS Mac's single `DeviceRecord(role: .mac)` — the one
    /// presence/profile record this device owns in DoomCoderZone. Replaces the
    /// old MacStatus singleton. The ServerRecordCache etag-preservation pattern
    /// keeps repeated heartbeats clean UPDATEs (single writer → no INSERT
    /// collisions).
    func publishMacStatus(sleepActive: Bool? = nil) {
        guard let engine else { return }
        let sm = SleepManager.shared

        let rec = DeviceRecord(
            deviceId: macId,
            role: .mac,
            displayName: macName,
            model: Self.macModel,
            osVersion: Self.macOSVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            lastSeen: Date(),
            accountName: macAccountName,
            accountEmail: macAccountEmail,
            sleepActive: sleepActive ?? sm.isActive,
            mode: sm.mode.rawValue,
            thermalState: sm.thermalStateText
        )
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(rec.recordID)])
        pendingMacStatus = rec
    }

    /// Best-effort iCloud identity of this Mac's account, captured once when
    /// known (e.g. during share creation). Carried on the Mac's DeviceRecord.
    var macAccountName: String?
    var macAccountEmail: String?

    /// Hardware model identifier (e.g. "MacBookPro18,3").
    static let macModel: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buf = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        if let nul = buf.firstIndex(of: 0) { buf.removeSubrange(nul...) }
        return String(decoding: buf, as: UTF8.self)
    }()

    /// "macOS 26.0" style string.
    static let macOSVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// Pull zone changes now. Used to pick up any new Mac state promptly
    /// (launch, foreground, wake, and the safety timer).
    func fetchNow() {
        // Task.detached (not Task {}): see kickEngine() — a plain Task inherits
        // the CKSyncEngine delegate-callback task-local marker and would crash
        // if fetchNow() is ever reached from a delegate-originated context.
        guard let engine else { return }
        Task.detached { try? await engine.fetchChanges() }
    }

    // MARK: - v5.2 manual refresh

    /// Continuously-updated flag the UI uses to drive a spinner
    /// around the refresh button. True while a manual `forceFetch()`
    /// is in flight (debounced to one in-flight at a time).
    @Published public private(set) var isFetching: Bool = false

    /// APNs registration status for honest diagnostics. `nil` = not yet
    /// known, `true` = registered with APNs, `false` = registration failed
    /// (e.g. missing `aps-environment` entitlement). Drives the Connections
    /// diagnostics + the "test notification" so we can report when silent
    /// push is simply unavailable rather than failing silently.
    @Published public private(set) var pushRegistered: Bool? = nil

    /// Set from the app delegate's APNs registration callbacks.
    func setPushRegistered(_ value: Bool) { pushRegistered = value }

    private var forceFetchTask: Task<Void, Never>?

    /// v5.2: invoked by the refresh button in ConnectionsView
    /// header. Calls `engine.fetchChanges()` directly (not via the
    /// silent-push path) so a missed APNs notification doesn't leave
    /// the Mac Connections tab stale for up to 60s. Also calls
    /// `kickEngine()` so any pending writes flush first.
    @MainActor
    public func forceFetch() {
        // Debounce: if a fetch is already in flight, drop this one.
        if forceFetchTask != nil { return }
        guard let engine else { return }
        isFetching = true
        forceFetchTask = Task { [weak self] in
            await MainActor.run { [weak self] in
                self?.kickEngine()
            }
            try? await engine.fetchChanges()
            // Give the engine a beat to materialise the
            // fetched records into our stores before we
            // flip isFetching off. Without this, the UI
            // un-spins before the data lands and the user
            // sees a brief flash of "no new data".
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run { [weak self] in
                self?.isFetching = false
                self?.forceFetchTask = nil
            }
        }
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
    var pendingMacStatus: DeviceRecord?
    var pendingAgentConfig: AgentConfigRecord?
    var pendingAgentIcons: [String: (AgentIconRecord, URL)] = [:]

    /// Called by the delegate to build the CKRecord for a queued save.
    /// Lesson #1 + #2 — singletons re-use the cached server CKRecord so the
    /// recordChangeTag is preserved.
    func buildRecord(for recordID: CKRecord.ID) -> CKRecord? {
        switch recordID.recordName {
        case let name where name.hasPrefix("NotificationLog-"):
            return pendingNotificationLogs[name]?.toCKRecord()
        case let name where name.hasPrefix("Device-"):
            // v7: the Mac's own DeviceRecord(role: .mac). Only ever the Mac's
            // own record is materialised here — a peer's Device-<iosId> record
            // is never queued for save.
            guard let rec = pendingMacStatus, name == "Device-\(macId)" else { return nil }
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
        if name == "Device-\(macId)"      { pendingMacStatus = nil }
        if name.hasPrefix("AgentConfig-") { pendingAgentConfig = nil }
        pendingAgentIcons.removeValue(forKey: name)
    }

    // MARK: - Send confirmation (honest test notification)

    private var sendConfirmations: [String: CheckedContinuation<Bool, Never>] = [:]

    /// Publishes a NotificationLog and awaits CloudKit's send confirmation.
    /// Returns `true` only once CKSyncEngine reports the record saved to the
    /// server, `false` on save failure or timeout. Used by the "test
    /// notification" diagnostic so it reflects real delivery to CloudKit
    /// rather than just a local enqueue.
    func publishNotificationLogAwaitingSend(_ rec: NotificationLogRecord,
                                            timeout: TimeInterval = 12) async -> Bool {
        guard let engine else { return false }
        let name = rec.recordID.recordName
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(rec.recordID)])
        pendingNotificationLogs[name] = rec
        kickEngine()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            sendConfirmations[name] = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run { self?.resolveSend(name: name, success: false) }
            }
        }
    }

    /// Resolves a pending send confirmation exactly once (first caller wins).
    /// Called by the delegate on `sentRecordZoneChanges` (success/failure) and
    /// by the timeout above.
    func resolveSend(name: String, success: Bool) {
        guard let cont = sendConfirmations.removeValue(forKey: name) else { return }
        cont.resume(returning: success)
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

extension CloudKitPusher {
    /// v7: ingest a peer iOS `DeviceRecord` fetched from DoomCoderZone.
    ///
    /// The DeviceRecord is upserted into the unified device store
    /// UNCONDITIONALLY (this fixes the headline bug: the old PeerStatus code
    /// dropped the profile whenever no Connection matched). The Mac therefore
    /// always knows the real iPhone identity. After storing, if a Connection
    /// exists for this iOS deviceId — or a CKShare connection whose placeholder
    /// iosDeviceId hasn't been reconciled yet — we refresh it and back-fill the
    /// real deviceId. Connection *state* is derived (DerivedDeviceState), not
    /// stamped from a heartbeat counter.
    @MainActor
    func ingestDeviceRecord(_ record: CKRecord) {
        guard let dev = DeviceRecord(record), dev.role == .ios else { return }

        // 1. Always store the peer profile so cards render the real identity.
        IosDeviceProfileCache.shared.upsert(dev)

        // 2. Feed the Add-Device "Same iCloud" picker so an unpaired iPhone is
        //    discoverable for an explicit connect.
        DiscoverableDeviceSubscription.shared.noteSeen(
            iosDeviceId: dev.deviceId,
            name: dev.displayName,
            model: dev.model,
            systemVersion: dev.osVersion,
            lastSeen: dev.lastSeen
        )

        // 3. Fast-path acceptance: if the Mac is showing the QR sheet, an iOS
        //    DeviceRecord appearing in the shared zone means the share was
        //    accepted (the iPhone can now write into the zone). Signal the
        //    coordinator so the sheet dismisses and the connection is reconciled.
        if case .waitingForAcceptance = MacPairingCoordinator.shared.phase {
            NotificationCenter.default.post(name: .doomCoderShareAccepted, object: nil)
        }

        // 4. Reconcile / refresh a matching Connection. Match by exact
        //    iosDeviceId, OR a CKShare row whose placeholder iosDeviceId hasn't
        //    been back-filled yet (there can be at most one such pending row).
        let connections = PairingStore.shared.connections
        let exact = connections.first { !$0.iosDeviceId.isEmpty && $0.iosDeviceId == dev.deviceId }
        let pendingShare = connections.first {
            $0.iosDeviceId.isEmpty && $0.ckShareRef != nil
        }
        guard let existing = exact ?? pendingShare else { return }

        var updated = existing
        if updated.iosDeviceId != dev.deviceId {
            updated.iosDeviceId = dev.deviceId   // reconcile placeholder → real id
        }
        // Drive status from the derivation so the UI keeps compiling on
        // Connection.status while we no longer run the CSC machine.
        let derived = DerivedDeviceState.derive(hasPairing: true, peer: dev)
        let wasActive = (updated.status == .active)
        switch derived {
        case .active:  updated.status = .active
        case .offline: updated.status = .suspended
        case .pending: updated.status = .pending
        case .disconnected: updated.status = .suspended
        }
        updated.lastSyncAt = dev.lastSeen
        if updated.removedAt != nil { updated.removedAt = nil }
        if let name = dev.accountName, !name.isEmpty { updated.peerAccountName = name }
        if let email = dev.accountEmail, !email.isEmpty { updated.peerAccountEmail = email }
        PairingStore.shared.upsert(updated)

        if !wasActive, derived == .active {
            NotificationDispatcher.shared.notifyDeviceConnected(name: dev.displayName)
        }
    }

    /// v7: a peer iOS DeviceRecord was DELETED from the zone (the iPhone
    /// disconnected from its side, or the shared zone was revoked). Drop the
    /// store entry and the matching Connection so the Mac list updates.
    @MainActor
    func handleDeviceRecordDeletion(recordName: String) {
        guard recordName.hasPrefix("Device-") else { return }
        let deviceId = String(recordName.dropFirst("Device-".count))
        // Never act on our own record's deletion.
        guard deviceId != macId, !deviceId.isEmpty else { return }
        IosDeviceProfileCache.shared.remove(deviceId: deviceId)
        let name = IosDeviceProfileCache.shared.name(for: deviceId)
        for conn in PairingStore.shared.connections where conn.iosDeviceId == deviceId {
            PairingStore.shared.remove(connectionId: conn.id)
        }
        NotificationDispatcher.shared.notifyDeviceDisconnected(name: name)
    }

    /// Legacy entry point retained for any stale callers; routes to the v7
    /// DeviceRecord ingest. PeerStatus records are no longer produced.
    @MainActor
    func ingestPeerStatus(_ record: CKRecord) {
        ingestDeviceRecord(record)
    }

}

extension Notification.Name {
    /// Posted on main thread once the CKSyncEngine is constructed and the
    /// zone exists. Subscribers may begin calling publish* methods.
    static let cloudKitPusherReady = Notification.Name("doomcoder.ckpusher.ready")
    /// v2.8: posted when a CKShare record in the Mac's zone is observed
    /// to have changed (typically: the iPhone just accepted the share).
    /// MacPairingCoordinator listens to this to dismiss the QR sheet
    /// and create the Connection — replaces the 3-second polling loop
    /// with an APNs-driven signal.
    static let doomCoderShareAccepted = Notification.Name("doomcoder.share.accepted")
}
