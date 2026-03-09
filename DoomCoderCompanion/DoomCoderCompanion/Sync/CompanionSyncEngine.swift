// CompanionSyncEngine.swift — DoomCoder Companion
// Full bidirectional CloudKit sync engine for the iOS companion, running two
// CKSyncEngines (private DB = same-Apple-ID Macs, shared DB = cross-account
// Macs after CKShare accept).
//   Fetches:  MacStatus, NotificationLog, AgentConfig, AgentIcon.
//   Produces: ControlCommand (sleep options, master toggle, snooze, .check),
//             CompanionStatus (device-presence heartbeat).
// All writes flow through the engines via state.add(pendingRecordZoneChanges:)
// + nextRecordZoneChangeBatch — never raw CKModifyRecordsOperation — so the
// engine owns change tags, batching, and retries.

import Foundation
import CloudKit
import UIKit
import UserNotifications
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

    /// Which database a given Mac's zone lives in. CloudKit rule: a Mac on the
    /// SAME Apple ID puts its zone in our PRIVATE database (one private DB is
    /// shared across all a user's devices); a Mac on a DIFFERENT Apple ID exposes
    /// its zone in our SHARED database after we accept its CKShare. So we run BOTH
    /// engines and route writes to the correct database per Mac.
    enum DBScope: String { case privateDB, sharedDB }

    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var sharedDB: CKDatabase { container.sharedCloudDatabase }

    /// macId → that Mac's zone ID (owner = the Mac), learned from fetched
    /// MacStatus records. Persisted so writes work before the first fetch.
    private var macZones: [String: CKRecordZone.ID] = [:]
    /// macId → which database its zone is in (private = same account).
    private var macScopes: [String: DBScope] = [:]

    private var privateEngine: CKSyncEngine?
    private var sharedEngine: CKSyncEngine?
    private var subscriptionsReady = false
    private var setupInProgress = false
    private var fetchInProgress = false

    /// The database to WRITE a record into for a given Mac (presence, commands).
    private func database(forMacId macId: String) -> CKDatabase {
        (macScopes[macId] == .sharedDB) ? sharedDB : privateDB
    }

    /// The CKSyncEngine that drives a given Mac's zone. All companion writes
    /// (ControlCommand, CompanionStatus presence) flow through the engine —
    /// never raw `CKModifyRecordsOperation` — so the engine owns change tags,
    /// batching, and retries. Same-Apple-ID Macs live in our PRIVATE database
    /// (we are the same iCloud owner); cross-account Macs live in the SHARED
    /// database after we accept their CKShare (participant with .readWrite).
    private func engine(forMacId macId: String) -> CKSyncEngine? {
        (macScopes[macId] == .sharedDB) ? sharedEngine : privateEngine
    }

    // MARK: - Outbound payloads (read by the engine's batch builder)

    /// In-flight ControlCommand payloads, keyed by recordName (unique per
    /// commandId). Mirrors the Mac's `pendingNotificationLogs`/`buildRecord`.
    @ObservationIgnored private var pendingCommands: [String: (rec: ControlCommandRecord, zid: CKRecordZone.ID)] = [:]
    /// In-flight CompanionStatus presence payloads. Keyed by
    /// "<zoneName>|<recordName>" because the SAME recordName
    /// ("CompanionStatus-<deviceId>") fans out to every connected Mac's zone.
    @ObservationIgnored private var pendingPresence: [String: (rec: CompanionStatusRecord, zid: CKRecordZone.ID)] = [:]
    /// Latest known SERVER CKRecord for each presence record (composite-keyed).
    /// CompanionStatus is a per-device singleton that already exists on the
    /// server (created by an earlier run / the pre-engine raw-write path), so a
    /// fresh engine state would otherwise try to INSERT it and hit
    /// "record to insert already exists" (CKError 14/2004) forever. We rebuild
    /// presence on this base so the recordChangeTag is preserved — mirroring the
    /// Mac's `ServerRecordCache`. Populated from fetches, successful saves, and
    /// the serverRecord returned on a conflict.
    @ObservationIgnored private var presenceServerRecords: [String: CKRecord] = [:]
    /// Bounded per-record conflict-retry counter (reset on success) so a
    /// pathological repeated serverRecordChanged can never spin forever.
    @ObservationIgnored private var presenceConflictAttempts: [String: Int] = [:]
    private static let maxPresenceConflictRetries = 3

    private static func presenceKey(zoneName: String, recordName: String) -> String {
        "\(zoneName)|\(recordName)"
    }

    /// Builds the CKRecord for a queued save. Commands are unique creates (no
    /// base). Presence is a singleton rebuilt on its last known server record so
    /// the change tag is preserved across saves and engine-state wipes.
    @MainActor
    private func buildRecord(for recordID: CKRecord.ID) -> CKRecord? {
        let name = recordID.recordName
        if name.hasPrefix("ControlCommand-") {
            return pendingCommands[name]?.rec.toCKRecord(in: recordID.zoneID)
        }
        if name.hasPrefix("CompanionStatus-") {
            let key = Self.presenceKey(zoneName: recordID.zoneID.zoneName, recordName: name)
            return pendingPresence[key]?.rec.toCKRecord(in: recordID.zoneID, base: presenceServerRecords[key])
        }
        return nil
    }

    /// Caches the latest server record for a presence singleton so the next
    /// publish carries the correct change tag.
    @MainActor
    private func notePresenceServerRecord(_ record: CKRecord) {
        guard record.recordType == CompanionStatusRecord.recordType else { return }
        let key = Self.presenceKey(zoneName: record.recordID.zoneID.zoneName,
                                   recordName: record.recordID.recordName)
        presenceServerRecords[key] = record
    }

    /// Drops the cached server base for a presence record so the next send is a
    /// fresh INSERT (used when the server reports the record no longer exists).
    @MainActor
    private func dropPresenceBase(for recordID: CKRecord.ID) {
        let key = Self.presenceKey(zoneName: recordID.zoneID.zoneName,
                                   recordName: recordID.recordName)
        presenceServerRecords[key] = nil
    }

    /// Drops an in-flight payload once the engine confirms the save.
    @MainActor
    private func clearPending(for recordID: CKRecord.ID) {
        let name = recordID.recordName
        pendingCommands.removeValue(forKey: name)
        let key = Self.presenceKey(zoneName: recordID.zoneID.zoneName, recordName: name)
        pendingPresence.removeValue(forKey: key)
        presenceConflictAttempts[key] = nil
    }

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

    /// Per-database engine state key (two engines → two keys).
    private static func engineStateKey(_ scope: DBScope) -> String {
        "ck.engineState.\(scope.rawValue)"
    }
    private var sharedDefaults: UserDefaults { AppGroupCache.defaults }

    // MARK: - Lifecycle

    func start() {
        Task { await setupSyncEngine() }
        startForegroundPolling()
        startHeartbeat()

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
                self.startHeartbeat()
                if self.privateEngine == nil && self.sharedEngine == nil {
                    // Reset any stale in-progress guard from a background hang
                    // so the fresh setup attempt is not silently skipped.
                    self.setupInProgress = false
                    await self.setupSyncEngine()
                } else {
                    await self.fetchChanges()
                    await self.publishCompanionStatus()
                }
            }
        }
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

    /// Requests a UIBackgroundTask slot and performs a final fetch+publish before
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
            await self?.publishCompanionStatus()
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
        // No-op kept for call-site compatibility. The engine persists its state
        // serialization to the app-group defaults on every `.stateUpdate`, and
        // UserDefaults flushes on its own. We must NOT call `synchronize()` — on
        // an app-group suite it triggers the "kCFPreferencesAnyUser with a
        // container ... detaching from cfprefsd" error and is a deprecated no-op.
    }

    // MARK: - Mac zone cache (participant addressing)

    private static let macZonesKey = "ck.ios.macZones.v1"

    private func loadMacZones() {
        guard let dict = sharedDefaults.dictionary(forKey: Self.macZonesKey) as? [String: String]
        else { return }
        for (macId, encoded) in dict {
            // Encoded as "zoneName|ownerName|scope".
            let parts = encoded.components(separatedBy: "|")
            if parts.count >= 2 {
                macZones[macId] = CKRecordZone.ID(zoneName: parts[0], ownerName: parts[1])
                if parts.count >= 3, let s = DBScope(rawValue: parts[2]) {
                    macScopes[macId] = s
                }
            }
        }
    }

    private func saveMacZones() {
        var dict: [String: String] = [:]
        for (macId, zid) in macZones {
            let scope = (macScopes[macId] ?? .privateDB).rawValue
            dict[macId] = "\(zid.zoneName)|\(zid.ownerName)|\(scope)"
        }
        sharedDefaults.set(dict, forKey: Self.macZonesKey)
    }

    /// Records the zoneID + database a Mac's records arrive in, so writes can be
    /// addressed back into the correct database/zone.
    private func noteMacZone(macId: String, zoneID: CKRecordZone.ID, scope: DBScope) {
        guard macZones[macId] != zoneID || macScopes[macId] != scope else { return }
        let isNewlyDiscovered = (macZones[macId] == nil)
        macZones[macId] = zoneID
        macScopes[macId] = scope
        saveMacZones()
        // Device acknowledgment, fast: the moment we learn a Mac's zone, push our
        // presence so the Mac shows this device as connected within seconds —
        // instead of waiting for the next 240 s heartbeat. The 240 s heartbeat
        // remains the steady-state keep-alive (inside the Mac's 600 s window).
        if isNewlyDiscovered {
            Task { @MainActor [weak self] in await self?.publishCompanionStatus() }
        }
    }

    /// The shared-zone ID for a given Mac, if known.
    private func zoneID(forMacId macId: String) -> CKRecordZone.ID? { macZones[macId] }

    // MARK: - Setup

    private func setupSyncEngine() async {
        guard !setupInProgress else {
            print("[CompanionSyncEngine] setupSyncEngine: re-entry guard — skipping")
            return
        }
        setupInProgress = true
        defer { setupInProgress = false }

        loadMacZones()

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

        // NOTE: participants do NOT create the zone — the Mac (owner) creates and
        // shares it. The accepted share's zone appears in our shared database; we
        // just point the engine at the shared database and fetch.

        if privateEngine != nil || sharedEngine != nil {
            privateEngine = nil
            sharedEngine = nil
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
        // Local-state reset generation (server-reset recovery): after a CloudKit
        // "Reset Development Environment" or any server-side wipe, the persisted
        // per-scope engine state + serverRecords go stale (deleted zones/records,
        // expired tokens). Bumping this generation forces ONE clean local wipe so
        // both engines re-fetch from zero — without requiring a reinstall.
        let resetGenKey = "ck.ios.localResetGeneration"
        let currentResetGen = 2
        let needsGenWipe = sharedDefaults.integer(forKey: resetGenKey) != currentResetGen

        if previousEnv != currentEnv || needsGenWipe {
            let reason = needsGenWipe ? "reset-gen \(currentResetGen)" : "env \(previousEnv ?? "nil") → \(currentEnv)"
            print("[CompanionSyncEngine] wiping stale local sync state (\(reason))")
            sharedDefaults.removeObject(forKey: Self.engineStateKey(.privateDB))
            sharedDefaults.removeObject(forKey: Self.engineStateKey(.sharedDB))
            serverRecords.clear()
            MacStatusStore.shared.clear()
            sharedDefaults.removeObject(forKey: "ck.ios.environment.v1")
            sharedDefaults.set(currentEnv, forKey: envKey)
            sharedDefaults.set(currentResetGen, forKey: resetGenKey)
        }

        func restore(_ scope: DBScope) -> CKSyncEngine.State.Serialization? {
            guard let data = sharedDefaults.data(forKey: Self.engineStateKey(scope)),
                  let s = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            else { return nil }
            return s
        }

        // Two participant engines: PRIVATE (same-Apple-ID Macs, auto-discovered)
        // and SHARED (different-Apple-ID Macs after CKShare accept). Both feed the
        // same record fan-out; writes are routed per-Mac by `database(forMacId:)`.
        privateEngine = CKSyncEngine(CKSyncEngine.Configuration(
            database: privateDB, stateSerialization: restore(.privateDB), delegate: self))
        sharedEngine = CKSyncEngine(CKSyncEngine.Configuration(
            database: sharedDB, stateSerialization: restore(.sharedDB), delegate: self))

        // Register subscriptions once per launch (on both databases)
        if !subscriptionsReady {
            subscriptionsReady = true
            await ensureSubscriptions()
        }

        await fetchAllEngines()
        await publishCompanionStatus()
    }

    /// Fetches both engines, tolerating per-engine errors (e.g. an empty shared
    /// database before any cross-account share is accepted).
    private func fetchAllEngines() async {
        for engine in [privateEngine, sharedEngine].compactMap({ $0 }) {
            do { try await engine.fetchChanges() }
            catch {
                SyncTelemetry.shared.record(.engineError, side: .ios,
                                            detail: "fetchChanges: \(error.localizedDescription)")
                print("[CompanionSyncEngine] fetchChanges error: \(error)")
            }
        }
    }

    // MARK: - Public API

    func fetchChanges() async {
        guard privateEngine != nil || sharedEngine != nil else {
            // Engines not initialised yet (e.g. pull-to-refresh fired before
            // setup finished). Attempt setup so a manual refresh does real work.
            if !setupInProgress { await setupSyncEngine() }
            return
        }
        guard !fetchInProgress else { return }
        fetchInProgress = true
        defer { fetchInProgress = false }
        await fetchAllEngines()
    }

    /// Clears the saved sync tokens and re-initialises both engines so the next
    /// fetch retrieves ALL records — not just incremental changes.
    /// Lighter than resetLocalSyncState(): does not wipe stores or environment keys.
    func forceFetchAll() async {
        sharedDefaults.removeObject(forKey: Self.engineStateKey(.privateDB))
        sharedDefaults.removeObject(forKey: Self.engineStateKey(.sharedDB))
        privateEngine = nil
        sharedEngine = nil
        zoneReady = false
        firstFetchCompleted = false
        setupInProgress = false          // Clear guard so setupSyncEngine() runs
        await setupSyncEngine()
    }

    // MARK: - Share acceptance (pairing)

    /// Accepts a Mac's zone-wide share from its share URL (QR-scan / pasted link
    /// path). Fetches the share metadata, accepts it, then fetches so the Mac's
    /// records (and its zone) appear immediately. Returns true on success.
    @discardableResult
    func acceptShare(at url: URL) async -> Bool {
        let metadata: CKShare.Metadata? = await withCheckedContinuation { cont in
            let op = CKFetchShareMetadataOperation(shareURLs: [url])
            op.shouldFetchRootRecord = false
            var found: CKShare.Metadata?
            op.perShareMetadataResultBlock = { _, result in
                if case .success(let m) = result { found = m }
            }
            op.fetchShareMetadataResultBlock = { _ in cont.resume(returning: found) }
            container.add(op)
        }
        guard let metadata else {
            print("[CompanionSyncEngine] acceptShare: could not fetch metadata for \(url)")
            return false
        }
        return await acceptShareMetadata(metadata)
    }

    /// Accepts share metadata delivered by the system (link tap →
    /// `userDidAcceptCloudKitShareWith`) or fetched from a URL.
    @discardableResult
    func acceptShareMetadata(_ metadata: CKShare.Metadata) async -> Bool {
        // SAME Apple ID: we are the share OWNER. You cannot (and need not) accept
        // your own share — the Mac's zone is already in our PRIVATE database. Just
        // make sure the engines are up and do a full fetch so the Mac appears.
        if metadata.participantRole == .owner {
            if privateEngine == nil && sharedEngine == nil { await setupSyncEngine() }
            await forceFetchAll()
            await publishCompanionStatus()
            return true
        }
        // Already accepted earlier? Just refresh.
        if metadata.participantStatus != .accepted {
            let ok: Bool = await withCheckedContinuation { cont in
                let op = CKAcceptSharesOperation(shareMetadatas: [metadata])
                op.acceptSharesResultBlock = { result in
                    switch result {
                    case .success: cont.resume(returning: true)
                    case .failure(let e):
                        print("[CompanionSyncEngine] acceptShares failed: \(e)")
                        cont.resume(returning: false)
                    }
                }
                container.add(op)
            }
            guard ok else { return false }
        }
        // Pull the newly-shared zone's records so MacStatus arrives and populates
        // macZones/macScopes for writes. forceFetchAll recreates engines so the
        // shared engine discovers the just-accepted zone.
        if privateEngine == nil && sharedEngine == nil { await setupSyncEngine() }
        await forceFetchAll()
        await publishCompanionStatus()
        return true
    }

    /// Disconnects from a Mac. For a DIFFERENT-account Mac (shared scope) we
    /// remove the shared zone from our shared database so we leave the share. For
    /// a SAME-account Mac (private scope) the zone holds the Mac's own data in our
    /// shared private DB — we must NOT delete it; we only forget it locally.
    func leaveShare(forMacId macId: String) async {
        if macScopes[macId] == .sharedDB, let zid = zoneID(forMacId: macId) {
            _ = try? await sharedDB.modifyRecordZones(saving: [], deleting: [zid])
        }
        macZones[macId] = nil
        macScopes[macId] = nil
        saveMacZones()
    }

    func handleRemoteNotification() async {
        SyncTelemetry.shared.record(.pushReceived, side: .ios)
        // If the engines never initialized (e.g. accountStatus failed at launch),
        // use the push arrival as an opportunity to re-attempt setup.
        if privateEngine == nil && sharedEngine == nil {
            await setupSyncEngine()
        }
        await fetchChanges()
    }

    // MARK: - Connection check (diagnostic)

    /// Fires a `.check` ControlCommand at the primary Mac, which rings a local
    /// notification ON THE MAC and acks via MacStatus — proving the iOS→Mac link
    /// end-to-end. Returns the commandId (for ack reconciliation) or nil. Unlike
    /// the old "test notification" (a NotificationLog that rang the iPhone itself),
    /// this is a real iOS→Mac message.
    @discardableResult
    func sendConnectionCheck() async -> String? {
        await sendControlCommand(verb: .check, value: "")
    }

    // MARK: - Remote control (iOS → Mac)

    /// Stable per-DEVICE identifier used as the command issuer and the key for
    /// this device's `CompanionStatusRecord` (recordName "CompanionStatus-<id>").
    ///
    /// Persisted in the Keychain so it survives app reinstalls and dev rebuilds —
    /// the old app-group UserDefaults store was wiped on every reinstall, minting
    /// a NEW id each time and registering the same phone as many ghost devices.
    ///
    /// Resolution order (first hit wins, then cached to Keychain):
    ///   1. Existing Keychain value.
    ///   2. Legacy UserDefaults value (migrated in, so this install keeps its id).
    ///   3. `identifierForVendor` (stable per device+vendor), else a fresh UUID.
    static let deviceIdService = "com.doomcoder.app.companion.identity"
    static let deviceIdAccount = "doomcoder.companion.deviceId"

    static var issuerDeviceId: String {
        if let kc = Keychain.get(account: deviceIdAccount, service: deviceIdService),
           !kc.isEmpty {
            return kc
        }
        let legacyKey = "doomcoder.companion.deviceId"
        let resolved = AppGroupCache.defaults.string(forKey: legacyKey)
            ?? UIDevice.current.identifierForVendor?.uuidString
            ?? UUID().uuidString
        Keychain.set(resolved, account: deviceIdAccount, service: deviceIdService)
        AppGroupCache.defaults.set(resolved, forKey: legacyKey)
        return resolved
    }

    private static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Writes a `ControlCommandRecord` targeting the primary Mac. The Mac applies
    /// it on its next fetch (launch / foreground / wake / push) and acks via
    /// `MacStatusRecord.lastAppliedCommandId`. Returns the `commandId` on a
    /// successful CloudKit write (so the caller can reconcile the ack), or nil
    /// on failure. A successful write does NOT mean the Mac has applied it yet.
    @discardableResult
    func sendControlCommand(verb: ControlCommandRecord.Verb, value: String) async -> String? {
        guard let primary = MacStatusStore.shared.primary else {
            print("[CompanionSyncEngine] sendControlCommand: no primary Mac")
            return nil
        }
        // The target Mac's zone is learned from a fetched MacStatus. If it isn't
        // known yet (e.g. first command right after launch), fetch once so the
        // command isn't silently dropped.
        var zid = zoneID(forMacId: primary.macId)
        if zid == nil {
            await fetchChanges()
            zid = zoneID(forMacId: primary.macId)
        }
        guard let zid else {
            print("[CompanionSyncEngine] sendControlCommand: no zone for \(primary.macId)")
            return nil
        }
        guard let eng = engine(forMacId: primary.macId) else {
            print("[CompanionSyncEngine] sendControlCommand: no engine for \(primary.macId)")
            return nil
        }
        let command = ControlCommandRecord(
            targetMacId: primary.macId,
            issuerDeviceId: Self.issuerDeviceId,
            verb: verb,
            value: value,
            clientVersion: Self.clientVersion
        )
        // Route through the engine: queue the payload, register the pending
        // change, and flush. The returned commandId means "queued" (not yet
        // server-acked) — callers (MacControlView) reconcile via the Mac's
        // MacStatus.lastAppliedCommandId ack-poll + timeout. A genuine send
        // failure surfaces in handleEvent(.sentRecordZoneChanges).
        let id = command.recordID(in: zid)
        pendingCommands[id.recordName] = (command, zid)
        eng.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        SyncTelemetry.shared.record(.localEdit, side: .ios,
                                    recordType: ControlCommandRecord.recordType,
                                    detail: "\(verb.rawValue)=\(value)")
        // Task.detached so a kick reached from any delegate-callback context can
        // never await re-entrantly into CKSyncEngine.
        Task.detached { try? await eng.sendChanges() }
        print("[CompanionSyncEngine] control command queued: \(verb.rawValue)=\(value)")
        return command.commandId
    }

    // MARK: - Presence heartbeat (iOS → Mac)

    /// Periodic heartbeat that publishes this device's presence so the Mac's
    /// Configure ▸ Connections tab can show real connected/unreachable status,
    /// symmetric to how the companion shows the Mac's status.
    @ObservationIgnored private var _heartbeatTimer: Timer?
    /// Stay comfortably inside the Mac's 600 s "connected" threshold.
    private let heartbeatInterval: TimeInterval = 240

    private func startHeartbeat() {
        stopHeartbeat()
        let t = Timer(timeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.publishCompanionStatus() }
        }
        RunLoop.main.add(t, forMode: .common)
        _heartbeatTimer = t
    }

    private func stopHeartbeat() {
        _heartbeatTimer?.invalidate()
        _heartbeatTimer = nil
    }

    /// Re-entrancy guard: only one presence save is in-flight at a time.
    @ObservationIgnored private var isPublishingPresence = false

    /// Publishes a `CompanionStatusRecord` describing this device into every
    /// connected Mac's zone, through the CKSyncEngine (the companion is a full
    /// producer). The engine owns change tags, batching, and retries; a
    /// stale/missing tag surfaces once as serverRecordChanged and is re-queued in
    /// handleEvent(.sentRecordZoneChanges). The `isPublishingPresence` guard keeps
    /// one publish in flight at a time.
    func publishCompanionStatus() async {
        guard accountAvailable, !isPublishingPresence else { return }
        isPublishingPresence = true
        await performPresenceSave()
        isPublishingPresence = false
    }

    private func performPresenceSave() async {
        // Publish presence into EVERY connected Mac's zone so each Mac shows this
        // device as connected — not just the active one. Until a Mac is known
        // (share accepted / MacStatus fetched), there's nowhere to write.
        let targets: [(macId: String, zid: CKRecordZone.ID)] = macScopes.keys.compactMap { macId in
            guard let zid = zoneID(forMacId: macId) else { return nil }
            return (macId, zid)
        }
        guard !targets.isEmpty else { return }

        let device = UIDevice.current
        // `device.name` is generic ("iPhone") since iOS 16 without an
        // Apple-approval-gated entitlement, so publish the resolved name (custom
        // name → marketing model) and the marketing model name explicitly.
        let custom = AppGroupCache.customDeviceName
        let model = DeviceModelName.current
        let status = CompanionStatusRecord(
            deviceId: Self.issuerDeviceId,
            name: custom.isEmpty ? model : custom,
            model: model,
            systemVersion: "\(device.systemName) \(device.systemVersion)",
            appVersion: Self.clientVersion,
            customDeviceName: custom
        )
        SyncTelemetry.shared.record(.localEdit, side: .ios,
                                    recordType: CompanionStatusRecord.recordType,
                                    detail: "presence heartbeat ×\(targets.count)")

        // Route each zone's save through its Mac's engine. The engine owns the
        // change tag (no manual base) — a stale/missing tag surfaces once as
        // serverRecordChanged in handleEvent(.sentRecordZoneChanges) and is
        // re-queued there. Flush each distinct engine once.
        var flushPrivate = false
        var flushShared = false
        for (macId, zid) in targets {
            guard let eng = engine(forMacId: macId) else { continue }
            let id = status.recordID(in: zid)
            pendingPresence[Self.presenceKey(zoneName: zid.zoneName, recordName: id.recordName)] = (status, zid)
            eng.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            if eng === sharedEngine { flushShared = true } else { flushPrivate = true }
        }
        if flushPrivate, let eng = privateEngine { Task.detached { try? await eng.sendChanges() } }
        if flushShared, let eng = sharedEngine { Task.detached { try? await eng.sendChanges() } }
        // Queued through the engine; delivery + retry are the engine's job.
    }

    func resetLocalSyncState() async {
        print("[CompanionSyncEngine] resetLocalSyncState: starting")
        SyncTelemetry.shared.record(.engineError, side: .ios,
                                    detail: "user-initiated local sync reset")
        
        privateEngine = nil
        sharedEngine = nil
        subscriptionsReady = false
        zoneReady = false
        firstFetchCompleted = false

        sharedDefaults.removeObject(forKey: Self.engineStateKey(.privateDB))
        sharedDefaults.removeObject(forKey: Self.engineStateKey(.sharedDB))
        sharedDefaults.removeObject(forKey: "ck.ios.environment.v1")
        sharedDefaults.removeObject(forKey: "ck.ios.environment.v2")

        await setupSyncEngine()
        print("[CompanionSyncEngine] resetLocalSyncState: done")
    }

    // MARK: - Subscriptions

    private func ensureSubscriptions() async {
        // Silent content-available subscriptions on BOTH databases: the private DB
        // catches same-Apple-ID Macs; the shared DB catches different-account Macs.
        await setupDatabaseSubscription(on: privateDB, id: "companion-private-db-sub-v1")
        await setupDatabaseSubscription(on: sharedDB, id: "companion-shared-db-sub-v1")
        // Clean up legacy private-DB query subscriptions: CKQuerySubscription is
        // NOT supported on the shared database, so visible notifications are now
        // delivered as LOCAL notifications after a silent-push fetch.
        for legacyID in ["notif-log-v6", "notif-log-v7", "notif-log-v8", "notif-log-v9"] {
            _ = try? await privateDB.deleteSubscription(withID: legacyID)
            _ = try? await sharedDB.deleteSubscription(withID: legacyID)
        }
    }

    /// Silent content-available subscription. Wakes the app on any change so it
    /// can fetch and post local notifications for new NotificationLog records.
    private func setupDatabaseSubscription(on database: CKDatabase, id: String) async {
        let sub = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        do {
            try await database.save(sub)
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            // Already exists
        } catch {
            print("[CompanionSyncEngine] DB subscription (\(id)) error: \(error)")
        }
    }

    // MARK: - Record fan-out

    @MainActor
    private func handleFetched(_ record: CKRecord, scope: DBScope) {
        do {
            switch record.recordType {
            case CloudKitConstants.RecordType.macStatus:
                if let r = MacStatusRecord(record) {
                    // Learn this Mac's zone + database so writes route correctly.
                    self.noteMacZone(macId: r.macId, zoneID: record.recordID.zoneID, scope: scope)
                    MacStatusStore.shared.upsert(r)
                    // Persist server record for changeTag
                    self.serverRecords.store(record)
                }

            case CloudKitConstants.RecordType.notificationLog:
                if let r = NotificationLogRecord(record) {
                    NotificationLogStore.shared.append(r)
                    // Shared DB can't use a query subscription, so the silent push
                    // brought us here — post a local notification for fresh events.
                    self.postLocalNotification(for: r)
                }

            case CompanionStatusRecord.recordType:
                // Our own heartbeat fetched back — cache its server record so the
                // next presence publish to that zone carries the correct change
                // tag (avoids the insert-vs-update 14/2004 conflict after an
                // engine-state wipe).
                self.notePresenceServerRecord(record)

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

    // MARK: - Local notifications (shared-DB delivery)

    /// Tracks already-posted notifIds so a re-fetch (incremental sync replay)
    /// doesn't double-post. Bounded ring persisted in the App Group.
    private static let postedNotifKey = "ck.ios.postedNotifIds.v1"

    /// Resolves a per-agent icon URL for a local notification. Order:
    ///   1. Bundled image (the iOS app target's asset catalog or the NSE
    ///      target's resources). Works on a fresh install before any
    ///      CloudKit AgentIcon fetch resolves.
    ///   2. App Group cache — CloudKit-pulled icons, possibly higher-res.
    ///   3. nil (no attachment).
    static func iconURL(for agent: TrackedAgent?, slug: String) -> URL? {
        if let agent, let url = Bundle.main.url(forResource: agent.bundledAssetName, withExtension: "png") {
            return url
        }
        if let url = AppGroupCache.iconURL(slug: agent?.iconSlug ?? slug) {
            return url
        }
        return nil
    }

    /// Posts a local notification for a freshly-fetched NotificationLog record.
    /// Required because the shared database can't use a CKQuerySubscription, so
    /// the server push is silent (content-available) and the app must render the
    /// banner itself. Dedups by notifId and ignores backfilled/old records.
    @MainActor
    private func postLocalNotification(for r: NotificationLogRecord) {
        // Only surface recent events (avoid a banner storm on first full sync).
        guard Date().timeIntervalSince(r.ts) < 600 else { return }

        var posted = sharedDefaults.stringArray(forKey: Self.postedNotifKey) ?? []
        guard !posted.contains(r.notifId) else { return }
        posted.append(r.notifId)
        if posted.count > 400 { posted.removeFirst(posted.count - 400) }
        sharedDefaults.set(posted, forKey: Self.postedNotifKey)

        let content = UNMutableNotificationContent()
        content.title = r.title.isEmpty ? r.macName : r.title
        content.body = r.body
        // "On <MacName>" subtitle. Helps users disambiguate when more than one
        // Mac is paired. Set only when non-empty so the system never renders a
        // blank subtitle.
        if !r.macName.isEmpty {
            content.subtitle = "On \(r.macName)"
        }
        content.sound = .default
        content.threadIdentifier = r.sessionKey           // group by session
        content.userInfo = ["notifId": r.notifId, "macId": r.macId, "agent": r.agent]
        if r.phase == NormalizedEventPhase.permissionNeeded.rawValue {
            content.interruptionLevel = .timeSensitive
        }
        // Attach the agent icon. Order of preference:
        //   1. Bundled image in the app's asset catalog — works on a fresh
        //      install before any CloudKit AgentIcon fetch resolves.
        //   2. App Group cache — CloudKit-pulled icons, may be higher-res.
        //   3. Skip (no attachment) if neither exists.
        let agent = TrackedAgent(rawValue: r.agent)
        if let iconURL = Self.iconURL(for: agent, slug: r.agent),
           let attachment = try? UNNotificationAttachment(identifier: "agent-icon", url: iconURL) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: r.notifId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - CKSyncEngineDelegate

extension CompanionSyncEngine: CKSyncEngineDelegate {

    /// Which database an engine instance drives (private = same Apple ID).
    @MainActor private func scope(of engine: CKSyncEngine) -> DBScope {
        engine === sharedEngine ? .sharedDB : .privateDB
    }

    nonisolated func handleEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {
        let scope = await scope(of: syncEngine)
        switch event {
        case .stateUpdate(let e):
            // Persist the engine state under its per-database key.
            if let data = try? JSONEncoder().encode(e.stateSerialization) {
                await MainActor.run {
                    AppGroupCache.defaults.set(data, forKey: Self.engineStateKey(scope))
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
                    self.handleFetched(change.record, scope: scope)
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
                await MainActor.run {
                    // Cache the just-saved server record (carries the fresh tag)
                    // so the next presence heartbeat updates instead of inserts.
                    self.notePresenceServerRecord(save)
                    self.clearPending(for: save.recordID)
                }
            }
            for fail in e.failedRecordSaves {
                let cke = fail.error
                SyncTelemetry.shared.record(.nacked, side: .ios,
                                            recordType: fail.record.recordType,
                                            detail: "\(cke.code.rawValue): \(cke.localizedDescription)")
                print("[CompanionSyncEngine] save failed on \(fail.record.recordID.recordName): \(cke.localizedDescription)")
                let recordID = fail.record.recordID
                switch cke.code {
                case .serverRecordChanged:
                    // "record to insert already exists" (14/2004): the record
                    // exists server-side but this engine doesn't know its tag
                    // (fresh engine state). Adopt the server record so the rebuild
                    // carries the right tag, then re-queue (bounded).
                    if let server = cke.serverRecord {
                        await MainActor.run { self.notePresenceServerRecord(server) }
                    }
                    await self.requeueAfterConflict(recordID, on: syncEngine)
                case .unknownItem:
                    // "recordChangeTag specified, but record not found" (11/2003):
                    // our cached base points at a record the server no longer has
                    // (e.g. after a dev-environment reset). Drop the stale base so
                    // the next send is a fresh insert, then re-queue.
                    await MainActor.run { self.dropPresenceBase(for: recordID) }
                    await self.requeueAfterConflict(recordID, on: syncEngine)
                default:
                    break
                }
            }

        default:
            break
        }
    }

    /// Re-adds a failed-on-conflict record to the engine's pending set and kicks
    /// a flush. MUST detach the kick — this runs inside a delegate callback and
    /// awaiting into the engine from there is a fatal CloudKit misuse.
    nonisolated private func requeueAfterConflict(_ recordID: CKRecord.ID, on engine: CKSyncEngine) async {
        let shouldRequeue = await MainActor.run { () -> Bool in
            let name = recordID.recordName
            // Commands are unique creates (UUID commandId) — a create-conflict is
            // effectively impossible, so never re-queue them (avoids any loop).
            if name.hasPrefix("ControlCommand-") { return false }
            let key = Self.presenceKey(zoneName: recordID.zoneID.zoneName, recordName: name)
            guard self.pendingPresence[key] != nil else { return false }
            // We just cached the server record, so the rebuild will carry the
            // correct tag and the retry should land. Bound the attempts so an
            // unexpected repeated conflict can't spin; the 240 s heartbeat is the
            // ultimate backstop. Counter resets on a successful save.
            let attempts = self.presenceConflictAttempts[key, default: 0]
            guard attempts < Self.maxPresenceConflictRetries else { return false }
            self.presenceConflictAttempts[key] = attempts + 1
            return true
        }
        guard shouldRequeue else { return }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        Task.detached { try? await engine.sendChanges() }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Companion is a full producer now: ControlCommand + CompanionStatus
        // presence are sent through the engine. Each engine pulls only its own
        // scoped pending changes; the batch closure serializes the matching
        // in-flight payload (built fresh — the engine owns the change tag).
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await self.buildRecord(for: recordID)
        }
    }
}
