import Foundation
import CloudKit
import IOKit
import AppKit
import OSLog
import DoomCoderCore

/// Single sync surface between the Mac app and iCloud (private DB).
///
/// Responsibilities:
///   • Lazy-bind: only does work when the user is signed into iCloud.
///   • Ensures `DoomCoderZone` exists (Mac is the canonical zone creator).
///   • Subscribes to the zone (silent push) + to `ControlCommand` records
///     for prompt remote-control delivery while the Mac is foregrounded.
///   • Coalesces enqueued record writes through a single
///     `CKModifyRecordsOperation` per debounce window so a burst of agent
///     events doesn't issue one CK op per event.
///   • Provides `publish(...)` convenience for each record type. Callers
///     don't have to know about CloudKit at all.
///
/// All public mutating API is `@MainActor`; the CK operation queue is a
/// separate serial queue so we never block the main thread on network I/O.
///
/// Failure mode is silent — sleep prevention and macOS local notifications
/// must continue working when the engine is unavailable (no iCloud,
/// container missing, schema mismatch, etc.). The Configure window
/// surfaces `lastError` for diagnostics.
@MainActor
@Observable
final class CloudKitSyncEngine {
    static let shared = CloudKitSyncEngine()

    // MARK: Public state (UI bindable)

    private(set) var isAvailable: Bool = false
    private(set) var accountStatusText: String = "Checking iCloud…"
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var pendingWrites: Int = 0

    // MARK: Internals

    private nonisolated let logger = Logger(subsystem: "com.doomcoder", category: "cloudkit")
    private let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName,
                                         ownerName: CKCurrentUserDefaultName)

    private var pendingSaves: [CKRecord] = []
    private var pendingDeletes: [CKRecord.ID] = []
    private var flushScheduled = false
    private var reauthScheduled = false

    /// Cumulative settings record; CloudKit upserts are merge-aware.
    private var currentSettings: SettingsRecord?

    // MARK: Identity

    /// Stable per-Mac identifier (hardware UUID).
    let macId: String = {
        let dict = IOServiceMatching("IOPlatformExpertDevice")
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, dict)
        defer { if svc != 0 { IOObjectRelease(svc) } }
        guard svc != 0,
              let cf = IORegistryEntryCreateCFProperty(svc, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        else { return UUID().uuidString }
        let uuid = (cf.takeRetainedValue() as? String) ?? UUID().uuidString
        return uuid
    }()

    var macName: String { Host.current().localizedName ?? "Mac" }

    // MARK: Lifecycle

    private init() {}

    func start() {
        logger.info("CloudKitSyncEngine.start() invoked, macId=\(self.macId, privacy: .public)")
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

    /// Public re-trigger of the iCloud account-status probe so Settings UI
    /// can offer a "Re-check iCloud" button.
    func refreshAccountStatusNow() async {
        await refreshAccountStatus()
    }

    private func refreshAccountStatus() async {
        do {
            let status = try await container.accountStatus()
            logger.info("accountStatus -> \(String(describing: status), privacy: .public)")
            switch status {
            case .available:
                isAvailable = true
                accountStatusText = "iCloud synced"
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
        // Step 1: zone (idempotent on the server).
        do {
            try await ensureZone()
            logger.info("ensureZone OK")
        } catch {
            lastError = error.localizedDescription
            logger.error("ensureZone failed: \(error.localizedDescription, privacy: .public)")
            // Without a zone, no further work is possible.
            return
        }

        // Step 2: publish initial MacStatus FIRST. This guarantees the
        // schema for at least one record type exists before we attempt
        // any query subscriptions. Without this, a first-ever launch
        // can fail at the subscription step and never auto-create the
        // schema — leaving the CloudKit dashboard empty.
        publishMacStatus()
        logger.info("initial MacStatus enqueued")

        // Step 3: subscriptions are best-effort. Push delivery is a
        // nice-to-have for prompt remote-control; the Mac still works
        // (just polls on its own clock) if these never get created.
        await ensureSubscriptionsBestEffort()

        // Step 4: register for APNs so silent pushes can wake the Mac.
        // Also best-effort.
        await MainActor.run {
            NSApplication.shared.registerForRemoteNotifications()
        }
        logger.info("registerForRemoteNotifications requested")
    }

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
                    // A zone that already exists is fine — CK reports this
                    // through .partialFailure with .serverRecordChanged
                    // sub-errors, or directly via .serverRejectedRequest.
                    if Self.isBenignAlreadyExistsError(err) {
                        cont.resume()
                    } else {
                        cont.resume(throwing: err)
                    }
                }
            }
            database.add(op)
        }
    }

    /// Creates the database-level silent subscription so the Mac is
    /// woken on any private-DB change (this is how the Mac learns of
    /// new `ControlCommand` records pushed by iOS).
    ///
    /// We intentionally do NOT create a `CKQuerySubscription` on
    /// `ControlCommand` here:
    ///   • On the very first launch the record type doesn't exist yet,
    ///     so the predicate `appliedAt == nil` would 400 with
    ///     `.invalidArguments` and block schema bootstrap.
    ///   • The database silent subscription is sufficient — Mac runs
    ///     `ControlCommandRouter.drainPending()` from the
    ///     `didReceiveRemoteNotification` handler.
    ///
    /// The iOS app owns its own query subscription on `NotificationLog`
    /// (with `shouldSendMutableContent = true`) for user-visible pushes.
    private func ensureSubscriptionsBestEffort() async {
        let dbSub = CKDatabaseSubscription(subscriptionID: "doomcoder-db-sub")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        dbSub.notificationInfo = info

        let op = CKModifySubscriptionsOperation(
            subscriptionsToSave: [dbSub],
            subscriptionIDsToDelete: nil
        )
        op.qualityOfService = .utility
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            op.modifySubscriptionsResultBlock = { [logger] result in
                switch result {
                case .success:
                    logger.info("ensureSubscriptions: db-sub OK")
                case .failure(let err):
                    if Self.isBenignAlreadyExistsError(err) {
                        logger.info("ensureSubscriptions: db-sub already exists")
                    } else {
                        logger.error("ensureSubscriptions failed (non-fatal): \(err.localizedDescription, privacy: .public)")
                    }
                }
                cont.resume()
            }
            database.add(op)
        }
    }

    /// CloudKit returns a wide variety of error codes when an op tries
    /// to recreate something that already exists or query a schema that
    /// isn't materialized yet. None of these are fatal for our purposes.
    private static func isBenignAlreadyExistsError(_ error: Error) -> Bool {
        guard let cke = error as? CKError else { return false }
        let benign: Set<CKError.Code> = [
            .serverRejectedRequest,
            .unknownItem,
            .invalidArguments,
            .serverRecordChanged
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

    // MARK: Publish API (called from app code)

    /// Heartbeat — publishes current sleep state, mode, timer, etc.
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

    /// Publishes a session aggregate snapshot. Idempotent (recordID stable).
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

    /// Appends an Event row.
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

    /// Records a NotificationLog row. iOS subscribes to this record type
    /// (CKQuerySubscription with mutable-content) so each creation produces
    /// a user-visible push the NSE renders.
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

    /// Touches a single settings field with the current timestamp (per-field
    /// LWW; see §12.6 of the design plan).
    func publishSettingsField(_ field: String, applyTo: (inout SettingsRecord) -> Void) {
        guard isAvailable else { return }
        var s = currentSettings ?? SettingsRecord()
        applyTo(&s)
        s.touch(field, by: macId)
        currentSettings = s
        enqueue(save: s.toCKRecord())
    }

    /// Marks a ControlCommand record as applied (or failed) so iOS can
    /// reconcile its optimistic UI.
    func acknowledgeCommand(_ record: ControlCommandRecord) {
        guard isAvailable else { return }
        enqueue(save: record.toCKRecord())
    }

    /// Upserts the local WoL profile so iOS can wake this Mac from LAN.
    func publishWoLProfile(_ rec: WoLProfileRecord) {
        guard isAvailable else { return }
        enqueue(save: rec.toCKRecord())
    }

    /// Manual end-to-end verification entry-point exposed from the
    /// Configure → Settings → "Send Test Ping" button. Publishes one
    /// MacStatus record and one NotificationLog record, which together
    /// exercise the entire write path (zone → record → schema auto-
    /// create → CK Dashboard visible row).
    func sendTestPing() {
        logger.info("sendTestPing tapped (isAvailable=\(self.isAvailable))")
        publishMacStatus()
        publishNotification(
            sessionKey: "test-\(UUID().uuidString.prefix(8))",
            agent: "claude",
            phase: "system",
            event: "test-ping",
            title: "DoomCoder Test Ping",
            body: "Manual ping from Configure → Settings.",
            channel: "iOSCompanion",
            success: true,
            ts: Date(),
            lastTool: nil,
            cwdBase: "~/"
        )
    }

    // MARK: Coalescing queue

    private func enqueue(save record: CKRecord) {
        pendingSaves.append(record)
        pendingWrites = pendingSaves.count + pendingDeletes.count
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            await self?.flush()
        }
    }

    private func flush() async {
        flushScheduled = false
        let saves = pendingSaves
        let deletes = pendingDeletes
        pendingSaves.removeAll()
        pendingDeletes.removeAll()
        pendingWrites = 0
        guard !saves.isEmpty || !deletes.isEmpty else { return }

        // Dedupe by recordID — keep the LAST write for any given record (last
        // wins for in-flight burst of session aggregate updates).
        var byID: [CKRecord.ID: CKRecord] = [:]
        for r in saves { byID[r.recordID] = r }
        let unique = Array(byID.values)

        let recordTypes = Set(unique.map(\.recordType)).sorted().joined(separator: ",")
        logger.info("flush: \(unique.count) saves [\(recordTypes, privacy: .public)] + \(deletes.count) deletes")

        let op = CKModifyRecordsOperation(recordsToSave: unique, recordIDsToDelete: deletes)
        // .allKeys ensures the very first write of a new record type carries
        // every field, so the auto-created schema is complete. .changedKeys
        // is incompatible with first-launch schema bootstrap.
        op.savePolicy = .allKeys
        op.qualityOfService = .utility
        op.modifyRecordsResultBlock = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.lastSyncAt = Date()
                    self.lastError = nil
                    self.logger.info("flush OK at \(self.lastSyncAt!)")
                case .failure(let err):
                    self.lastError = err.localizedDescription
                    self.logger.error("modifyRecords failed: \(err.localizedDescription, privacy: .public)")
                    if let cke = err as? CKError, cke.code == .notAuthenticated {
                        self.scheduleReauth()
                    }
                }
            }
        }
        database.add(op)
    }

    /// One-shot recovery: if a publish fails because iCloud auth dropped,
    /// re-run accountStatus 5 s later. Guarded so a burst of failures
    /// doesn't queue dozens of probes.
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

    // MARK: Helpers

    private nonisolated func sha256(_ s: String) -> String {
        // Lightweight non-crypto digest fallback (CryptoKit kept out to avoid
        // adding a framework just for this). 64-bit hash printed hex.
        var h: UInt64 = 1469598103934665603
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 1099511628211
        }
        return String(h, radix: 16)
    }
}
