// CompanionSyncEngine.swift — DoomCoder Companion
// The central CloudKit sync coordinator for the iOS companion app.
// Uses CKSyncEngine (iOS 17+) for efficient, delta-based synchronisation of
// the DoomCoderZone. Decodes incoming records and fans them out to the
// appropriate Observable stores.

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
    /// Flips true the first time `.fetchedRecordZoneChanges` resolves
    /// (regardless of result count) so the UI can distinguish "first fetch
    /// is in flight" from "fetch completed but no Mac has paired yet".
    var firstFetchCompleted: Bool = false

    // MARK: - Private CloudKit plumbing

    private let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
    private var db: CKDatabase { container.privateCloudDatabase }
    private var zone: CKRecordZone { CKRecordZone(zoneName: CloudKitConstants.zoneName) }

    private var syncEngine: CKSyncEngine?

    /// Prevents subscriptions from being registered more than once per launch.
    private var subscriptionsReady = false

    /// Re-entry guard: CKAccountChanged can fire during ensureZone() /
    /// ensureSubscriptions(), triggering a second concurrent setupSyncEngine().
    /// Two concurrent engines for the same zone cause a race and crash.
    private var setupInProgress = false

    /// Records queued for the next CKSyncEngine push batch, keyed by recordID
    /// so a rapid second edit to the same record overwrites the first instead
    /// of producing two `.saveRecord(sameID)` entries (which CloudKit rejects
    /// as "You can't save the same record twice").
    private var recordsByID: [CKRecord.ID: CKRecord] = [:]
    private var settingsSaveSerial: UInt64 = 0

    // MARK: - Defaults key for engine state

    private static let engineStateKey = "ck.engineState"
    private var sharedDefaults: UserDefaults { AppGroupCache.defaults }

    // MARK: - Lifecycle

    func start() {
        Task { await setupSyncEngine() }
        // Re-bootstrap when the iCloud account changes mid-session
        // (sign-in after first launch, switch accounts, etc.) so the engine
        // doesn't stay stuck in "not available" until app relaunch.
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.setupSyncEngine() }
        }
        // Defensive: flush CKSyncEngine state to disk when iOS suspends us,
        // so a force-quit / OS kill mid-write doesn't strand the delta token.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.persistEngineStateNow() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.persistEngineStateNow() }
        }
    }

    /// Defensive flush hook for app background/terminate. The `.stateUpdate`
    /// event handler is the canonical persistence path; this just forces the
    /// shared App Group defaults to flush dirty pages to disk so an OS kill
    /// immediately after a recent .stateUpdate cannot strand the token.
    func persistEngineStateNow() {
        sharedDefaults.synchronize()
        print("[CompanionSyncEngine] persistEngineStateNow: shared defaults synchronized")
    }

    /// Idempotently creates DoomCoderZone in the private DB. CKSyncEngine
    /// does NOT auto-create custom zones; without this, iOS pushes fail with
    /// `.zoneNotFound` on a fresh iCloud account or after a dev zone wipe.
    /// Mirrors the Mac's `ensureZone()` path.
    private func ensureZone() async {
        let z = CKRecordZone(zoneID: zone.zoneID)
        let op = CKModifyRecordZonesOperation(recordZonesToSave: [z], recordZoneIDsToDelete: nil)
        op.qualityOfService = .userInitiated
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            op.modifyRecordZonesResultBlock = { result in
                if case .failure(let err) = result {
                    if let cke = err as? CKError,
                       cke.code == .serverRecordChanged || cke.code == .unknownItem {
                        // Already exists or transient — treat as success.
                    } else {
                        print("[CompanionSyncEngine] ensureZone error: \(err)")
                    }
                }
                cont.resume()
            }
            db.add(op)
        }
    }

    private func setupSyncEngine() async {
        // Prevent concurrent setups. CKAccountChanged fires during ensureZone()
        // which would trigger a second setupSyncEngine() while the first is
        // still in flight, tearing down syncEngine out from under it.
        guard !setupInProgress else {
            print("[CompanionSyncEngine] setupSyncEngine: re-entry guard — skipping")
            return
        }
        setupInProgress = true
        defer { setupInProgress = false }

        // Verify account status first.
        do {
            let status = try await container.accountStatus()
            accountAvailable = (status == .available)
        } catch {
            accountAvailable = false
            print("[CompanionSyncEngine] accountStatus error: \(error)")
        }

        guard accountAvailable else { return }

        // Ensure the zone exists before constructing the engine. Today this
        // works only because the Mac creates the zone; after a dev wipe or
        // on a fresh iCloud account where the iOS app launches first, the
        // engine would otherwise loop with .zoneNotFound on every push.
        await ensureZone()

        // If the engine was already constructed on a previous account, tear
        // it down so we re-init with the (possibly different) state.
        if syncEngine != nil { syncEngine = nil }

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

        let engine = CKSyncEngine(config)
        syncEngine = engine
        // Re-assert the zone in the engine's database state. CKSyncEngine
        // does NOT auto-track custom zones across launches even when they
        // exist on the server — without this, restored state emits the
        // "finished fetching changes for a zone that it never started"
        // warning and skips delta fetches. Idempotent.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone.zoneID))])

        // Register subscriptions once per launch after the engine is up.
        if !subscriptionsReady {
            subscriptionsReady = true
            await ensureSubscriptions()
        }

        // Pre-populate the ServerRecordCache so the first user toggle after a
        // cold launch carries a valid recordChangeTag. This must be an
        // explicit fetch-by-ID: CKSyncEngine.fetchChanges() is delta-based and
        // can return nothing when its token is already current, leaving a
        // freshly installed app-group cache empty.
        await prewarmSettingsRecordCache()
        try? await engine.fetchChanges()
    }

    // MARK: - Public API

    func fetchChanges() async {
        guard let engine = syncEngine else { return }
        try? await engine.fetchChanges()
    }

    func handleRemoteNotification() async {
        await fetchChanges()
    }

    private func fetchSettingsServerRecord() async -> CKRecord? {
        await withCheckedContinuation { (cont: CheckedContinuation<CKRecord?, Never>) in
            let op = CKFetchRecordsOperation(recordIDs: [SettingsRecord.recordID])
            op.qualityOfService = .userInitiated
            var out: CKRecord?
            op.perRecordResultBlock = { _, result in
                if case .success(let record) = result { out = record }
            }
            op.fetchRecordsResultBlock = { _ in cont.resume(returning: out) }
            db.add(op)
        }
    }

    private func prewarmSettingsRecordCache() async {
        guard let fresh = await fetchSettingsServerRecord(),
              let remote = SettingsRecord(fresh) else { return }
        SettingsStore.shared.applyRemote(remote, rawRecord: fresh)
        print("[CompanionSyncEngine] prewarm Settings-singleton OK")
    }

    private func ensureSubscriptions() async {
        await setupDatabaseSubscription()
        await setupNotificationLogSubscription()
        await setupMacStatusSubscription()
        await setupSessionSubscription()
    }

    /// Enqueue a CKRecord for the next outbound sync batch.
    /// Latest write per recordID wins (overwrites in-flight queued copy).
    func enqueueSave(_ record: CKRecord) {
        recordsByID[record.recordID] = record
        syncEngine?.state.add(pendingRecordZoneChanges: [
            CKSyncEngine.PendingRecordZoneChange.saveRecord(record.recordID)
        ])
    }

    /// Enqueue a Settings change. We rely on:
    ///   1) the cold-launch `prewarmSettingsRecordCache()` + `fetchChanges()`,
    ///   2) the engine's normal delta-fetch / push-driven cache updates,
    ///   3) CKSyncEngine's built-in conflict recovery (.serverRecordChanged)
    /// to keep `SettingsStore.serverRecord` carrying a current
    /// recordChangeTag. The old per-write preflight fetch raced with the
    /// engine, occasionally clobbering the user's just-typed value with a
    /// stale server snapshot.
    func enqueueSettingsSave(_ settings: SettingsRecord) {
        settingsSaveSerial &+= 1
        let base = SettingsStore.shared.serverRecord
        enqueueSave(settings.toCKRecord(base: base))
        maybeFireWakeOnLAN()
    }

    /// Fire a magic packet only when (a) the Mac is reported as sleeping or
    /// hasn't checked in for > 2 minutes AND (b) we have a usable MAC +
    /// broadcast address from the latest MacStatusRecord. Best-effort: WoL
    /// only works on the same LAN — over cellular the packet has nowhere
    /// to go and we silently rely on APNs wake-for-network.
    private func maybeFireWakeOnLAN() {
        guard let mac = MacStatusStore.shared.primary,
              let macAddr = mac.macAddress,
              let bcast = mac.broadcastIPv4 else { return }
        let stale = Date().timeIntervalSince(mac.lastSeen) > 120
        guard mac.sleepActive || stale else { return }
        // Off-main to avoid blocking the actor with the synchronous sendto loop.
        Task.detached(priority: .utility) {
            _ = WakeOnLAN.wake(macAddress: macAddr, broadcastIPv4: bcast)
        }
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
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            // Already exists — that is fine.
        } catch {
            print("[CompanionSyncEngine] DB subscription error: \(error)")
        }
    }

    private func setupNotificationLogSubscription() async {
        // Delete all previous subscription versions.
        for id in ["companion-notiflog-sub", "companion-notiflog-sub-v2",
                   "companion-notiflog-sub-v3", "companion-notiflog-sub-v4",
                   "companion-notiflog-sub-v5", "companion-notiflog-sub-v6",
                   "companion-notiflog-sub-v7"] {
            _ = try? await db.deleteSubscription(withID: id)
        }

        let yesterday = Date(timeIntervalSinceNow: -86_400)
        let pred = NSPredicate(format: "ts > %@", yesterday as NSDate)
        let sub = CKQuerySubscription(
            recordType: CloudKitConstants.RecordType.notificationLog,
            predicate: pred,
            subscriptionID: "companion-notiflog-sub-v8",
            options: .firesOnRecordCreation
        )
        let info = CKSubscription.NotificationInfo()
        // Use title/body localization-key substitution so APNs delivers the
        // Mac-rendered title and body in `aps.alert.title` / `aps.alert.body`
        // *directly*. The OS displays the right text even if the NSE never
        // runs (low-power / killed extension / decode failure). NSE then only
        // adds icon attachment, thread identifier, and interruption level.
        //
        // "%@" with a single CKRecord field name in the args array tells
        // CloudKit to substitute that field's string value verbatim. This is
        // the canonical way to wire query subscriptions to real push content.
        info.titleLocalizationKey  = "%@"
        info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey  = "%@"
        info.alertLocalizationArgs = ["body"]
        info.shouldSendMutableContent = true   // invokes NSE on each push
        info.soundName = "default"
        // v8 desiredKeys (CloudKit hard limit: 5):
        //   title      → aps.alert.title via titleLocalizationArgs (also NSE fallback)
        //   body       → aps.alert.body  via alertLocalizationArgs (also NSE fallback)
        //   agent      → icon slug + interruption level
        //   phase      → interruption level
        //   sessionKey → UNNotification threadIdentifier
        info.desiredKeys = ["title", "body", "agent", "phase", "sessionKey"]
        sub.notificationInfo = info
        sub.zoneID = zone.zoneID
        do {
            try await db.save(sub)
            print("[CompanionSyncEngine] notiflog sub v8 registered")
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            print("[CompanionSyncEngine] notiflog sub v8 already exists")
        } catch {
            print("[CompanionSyncEngine] NotifLog subscription error: \(error)")
        }
    }

    private func setupMacStatusSubscription() async {
        let sub = CKQuerySubscription(
            recordType: CloudKitConstants.RecordType.macStatus,
            predicate: NSPredicate(value: true),
            subscriptionID: "companion-macstatus-sub-v1",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        sub.zoneID = zone.zoneID
        do {
            try await db.save(sub)
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            // Already exists.
        } catch {
            print("[CompanionSyncEngine] MacStatus subscription error: \(error)")
        }
    }

    private func setupSessionSubscription() async {
        let sub = CKQuerySubscription(
            recordType: CloudKitConstants.RecordType.session,
            predicate: NSPredicate(value: true),
            subscriptionID: "companion-session-sub-v1",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        sub.zoneID = zone.zoneID
        do {
            try await db.save(sub)
        } catch let e as CKError where e.code == .serverRejectedRequest || e.code == .unknownItem {
            // Already exists.
        } catch {
            print("[CompanionSyncEngine] Session subscription error: \(error)")
        }
    }

    // MARK: - Conflict recovery

    /// Mirrors the Mac's `CloudKitSyncEngine.recoverFromServerRecordChanged`
    /// path. When CloudKit rejects a save with `.serverRecordChanged`
    /// (the 14/2004 "record to insert already exists" flood the iOS
    /// companion was looping on), do an explicit `CKFetchRecordsOperation`
    /// for *this* recordID so we re-acquire its `recordChangeTag`, then
    /// re-cache + re-enqueue against the fresh base. A delta
    /// `fetchChanges()` is not sufficient — if no other client has moved
    /// the server side since our last token, the delta is empty and we
    /// stay stuck.
    nonisolated private func recoverFromServerRecordChanged(
        id: CKRecord.ID,
        recordType: String,
        localCopy: CKRecord
    ) async {
        // Drop the stale pending change first so the engine doesn't retry
        // the tag-less save while we're fetching.
        if let engine = await MainActor.run(body: { self.syncEngine }) {
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
        }
        await MainActor.run {
            _ = self.recordsByID.removeValue(forKey: id)
        }

        let db: CKDatabase = await MainActor.run { self.db }
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
            print("[CompanionSyncEngine] recover: fetch by ID returned nil for \(id.recordName)")
            return
        }

        await MainActor.run {
            switch recordType {
            case CloudKitConstants.RecordType.settings:
                // Cache the fresh tag, merge server values into local
                // state, then re-enqueue the user's pending edit so it
                // isn't silently dropped.
                if let remote = SettingsRecord(fresh) {
                    SettingsStore.shared.applyRemote(remote, rawRecord: fresh)
                }
                let merged = SettingsStore.shared.current
                self.enqueueSave(merged.toCKRecord(base: SettingsStore.shared.serverRecord))
            case CloudKitConstants.RecordType.controlCommand:
                // iOS commands are one-shot inserts — the conflict means
                // the Mac already acked. Apply the freshly-fetched ack so
                // the optimistic UI state reconciles.
                if let cmd = ControlCommandRecord(fresh) {
                    CommandPublisher.shared.handleEcho(cmd)
                }
            default:
                break
            }
        }
    }

    // MARK: - Record fan-out

    nonisolated private func handleFetched(_ record: CKRecord) {
        // Task { @MainActor in } creates an unstructured task (not a child of the
        // CKSyncEngine delegate tree) that runs on the main actor. This avoids the
        // reentrancy crash that would occur with a structured child task, and avoids
        // the Swift 6 region-isolation checker bug triggered by Task.detached { @MainActor in }.
        Task { @MainActor in
            switch record.recordType {
            case CloudKitConstants.RecordType.macStatus:
                if let r = MacStatusRecord(record) { MacStatusStore.shared.upsert(r) }
            case CloudKitConstants.RecordType.session:
                if let r = SessionRecord(record) {
                    SessionStore.shared.upsert(r)
                    // Drive Live Activity updates from session record changes.
                    #if canImport(ActivityKit) && os(iOS)
                    if #available(iOS 16.1, *) {
                        if r.hasEnded || r.hasFailed {
                            await LiveActivityManager.shared.end(sessionKey: r.sessionKey)
                        } else {
                            await LiveActivityManager.shared.update(r)
                        }
                    }
                    #endif
                }
            case CloudKitConstants.RecordType.notificationLog:
                if let r = NotificationLogRecord(record) { NotificationLogStore.shared.append(r) }
            case CloudKitConstants.RecordType.settings:
                if let r = SettingsRecord(record) { SettingsStore.shared.applyRemote(r, rawRecord: record) }
            case CloudKitConstants.RecordType.agentIcon:
                if let r = AgentIconRecord(record), let asset = r.pngAsset,
                   let fileURL = asset.fileURL,
                   let data = try? Data(contentsOf: fileURL) {
                    let slug = TrackedAgent(rawValue: r.agent)?.iconSlug ?? r.agent
                    AppGroupCache.writeIcon(slug: slug, data: data)
                }
            case CloudKitConstants.RecordType.controlCommand:
                // Mac stamps appliedAt + result after processing the command.
                // Route the updated record to CommandPublisher so the stream
                // completes with the real Mac acknowledgement.
                if let r = ControlCommandRecord(record) { CommandPublisher.shared.handleEcho(r) }
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
                    self.recordsByID.removeAll()
                case .switchAccounts:
                    MacStatusStore.shared.clear()
                    SessionStore.shared.clear()
                    SettingsStore.shared.clear()
                    NotificationLogStore.shared.entries.removeAll()
                    self.recordsByID.removeAll()
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
                self.firstFetchCompleted = true
                self.lastSyncAt = Date()
            }

        case .willSendChanges:
            break

        case .sentRecordZoneChanges(let e):
            // Drop successfully-saved records from our local queue map.
            if !e.savedRecords.isEmpty {
                let savedIDs = e.savedRecords.map(\.recordID)
                await MainActor.run {
                    for id in savedIDs { self.recordsByID.removeValue(forKey: id) }
                }
            }
            for save in e.savedRecords {
                if save.recordType == CloudKitConstants.RecordType.settings {
                    // Persist the server changeTag so the next user edit
                    // performs an UPDATE rather than another INSERT.
                    await MainActor.run { SettingsStore.shared.serverRecord = save }
                }
                if save.recordType == CloudKitConstants.RecordType.controlCommand,
                   let cmd = ControlCommandRecord(save) {
                    await MainActor.run {
                        CommandPublisher.shared.handleEcho(cmd)
                    }
                }
            }
            // When a record fails with .serverRecordChanged, the server already
            // has a newer copy. Industry best practice (and what the Mac side
            // does in CloudKitSyncEngine.recoverFromServerRecordChanged) is
            // to fetch that specific record by ID via CKFetchRecordsOperation
            // so we re-acquire its recordChangeTag, then re-upsert against
            // the fresh `base`. A delta `fetchChanges()` may return nothing
            // (the server hasn't moved since our last token) and leaves us
            // stuck in a tag-less-INSERT loop.
            if !e.failedRecordSaves.isEmpty {
                for fail in e.failedRecordSaves {
                    let cke = fail.error
                    print("[CompanionSyncEngine] save conflict on \(fail.record.recordID.recordName): \(cke.localizedDescription)")
                    if cke.code == .serverRecordChanged {
                        await self.recoverFromServerRecordChanged(
                            id: fail.record.recordID,
                            recordType: fail.record.recordType,
                            localCopy: fail.record
                        )
                    } else {
                        // Non-conflict failures: drop the stale record from
                        // our queue. The engine has already decided whether
                        // to keep or drop the pending change.
                        await MainActor.run {
                            _ = self.recordsByID.removeValue(forKey: fail.record.recordID)
                        }
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
        // Canonical pattern: use the engine's deduped pending-change list
        // (filtered by send scope) and serve records from our local map.
        // The engine guarantees each recordID appears at most once here, so
        // the resulting batch can never contain duplicate save entries.
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        let snapshot: [CKRecord.ID: CKRecord] = await MainActor.run { self.recordsByID }

        // Split into Settings vs everything-else so each batch uses the
        // appropriate savePolicy.
        //
        // Settings: .ifServerRecordUnchanged so per-field LWW survives
        //   concurrent Mac edits. SettingsStore caches the server CKRecord
        //   and passes it as `base` to toCKRecord, so each write carries the
        //   server changeTag. Conflicts resurface as .serverRecordChanged
        //   and are recovered via re-fetch in sentRecordZoneChanges.
        //
        // ControlCommand / others: .allKeys so freshly-created records with
        //   no prior server changeTag don't get rejected as
        //   "record to insert already exists" (CKError 14/2004).
        let settingsName = SettingsRecord.singletonRecordName
        let settingsChanges = changes.filter { change in
            switch change {
            case .saveRecord(let id):   return id.recordName == settingsName
            case .deleteRecord(let id): return id.recordName == settingsName
            @unknown default:           return false
            }
        }
        if !settingsChanges.isEmpty {
            return await CKSyncEngine.RecordZoneChangeBatch(
                pendingChanges: settingsChanges,
                recordProvider: { id in snapshot[id] }
            )
        }

        let batch = await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: changes,
            recordProvider: { id in snapshot[id] }
        )
        return batch
    }
}
