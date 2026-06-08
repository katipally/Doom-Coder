// CloudKitPusherDelegate.swift
//
// CKSyncEngineDelegate for the Mac push-only pipeline.

import Foundation
import CloudKit
import OSLog
import Observation
import DoomCoderCore

final class CloudKitPusherDelegate: NSObject, CKSyncEngineDelegate, @unchecked Sendable {

    private let logger = Logger(subsystem: "com.doomcoder", category: "ckpusher.delegate")
    private weak var pusher: CloudKitPusher?
    private let stateKey: String

    /// Audit 2026-06: the brief 300ms delay before re-kicking the engine
    /// after a recovery (see `handleEvent` below) is named here so a
    /// future reader can understand the trade-off. The delay gives the
    /// engine time to finish its current send cycle so our re-queue
    /// doesn't race the in-flight save.
    private static let engineRecoveryKickDelay: Duration = .milliseconds(300)

    init(pusher: CloudKitPusher, stateKey: String) {
        self.pusher = pusher
        self.stateKey = stateKey
    }

    // MARK: - Engine events

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let upd):
            await persistState(upd.stateSerialization)

        case .accountChange(let change):
            // Lesson #3 — wipe local server-record cache and let
            // CloudKitPusher.setupSyncEngine rebuild.
            await MainActor.run {
                self.pusher?.serverRecords.clear()
                NotificationCenter.default.post(name: .cloudKitPusherReady, object: nil)
            }
            logger.notice("ckpusher.delegate: accountChange \(String(describing: change.changeType), privacy: .public)")

        case .sentRecordZoneChanges(let sent):
            for saved in sent.savedRecords {
                // Lesson #1 — persist server-known CKRecord for singletons
                await MainActor.run {
                    self.pusher?.serverRecords.store(saved)
                    self.pusher?.clearPending(for: saved.recordID)
                }
            }
            var needsRecoveryKick = false
            for failed in sent.failedRecordSaves {
                let code = failed.error.code
                logger.error("ckpusher.delegate: failed save \(failed.record.recordID.recordName, privacy: .public) code=\(String(describing: code), privacy: .public)")
                let recordID = failed.record.recordID
                switch code {
                case .serverRecordChanged:
                    // Conflict: adopt the server's record so the next save carries
                    // the correct change tag.
                    if let serverRec = failed.error.serverRecord {
                        await MainActor.run { self.pusher?.serverRecords.store(serverRec) }
                    }
                case .unknownItem:
                    // Stale base tag for a record the server no longer has
                    // (e.g. after a dev-environment reset) → re-insert fresh.
                    await MainActor.run { self.pusher?.recoverUnknownItem(recordID) }
                    needsRecoveryKick = true
                case .zoneNotFound, .userDeletedZone:
                    // Our zone is gone → recreate it and re-insert.
                    await MainActor.run { self.pusher?.recoverZoneNotFound(recordID) }
                    needsRecoveryKick = true
                default:
                    if let serverRec = failed.error.serverRecord {
                        await MainActor.run { self.pusher?.serverRecords.store(serverRec) }
                    }
                }
            }
            if needsRecoveryKick {
                // Defer the flush — never call sendChanges() re-entrantly from a
                // delegate callback. The brief delay lets the engine finish the
                // current send before we re-queue the recovered changes.
                Task { @MainActor [weak pusher] in
                    try? await Task.sleep(for: Self.engineRecoveryKickDelay)
                    pusher?.kickEngine()
                }
            }

        case .sentDatabaseChanges:
            break

        case .fetchedRecordZoneChanges(let fetched):
            // Audit 2026-06: instrument the iOS→Mac receive path. Log how many
            // records the poll/push actually pulled and the per-type tally so we
            // can see whether ControlCommands are arriving at all (vs being
            // dropped by the apply filter, vs the fetch returning nothing).
            if !fetched.modifications.isEmpty || !fetched.deletions.isEmpty {
                var tally: [String: Int] = [:]
                for mod in fetched.modifications { tally[mod.record.recordType, default: 0] += 1 }
                let summary = tally.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
                logger.notice("ckpusher.delegate: fetched \(fetched.modifications.count, privacy: .public) mod / \(fetched.deletions.count, privacy: .public) del [\(summary, privacy: .public)]")
            }
            var commands: [ControlCommandRecord] = []
            var commandRecordIDs: [String: CKRecord.ID] = [:]   // commandId → CKRecord.ID
            for mod in fetched.modifications {
                let record = mod.record
                await MainActor.run { self.pusher?.serverRecords.store(record) }
                if record.recordType == ControlCommandRecord.recordType,
                   let cmd = ControlCommandRecord(record) {
                    commands.append(cmd)
                    commandRecordIDs[cmd.commandId] = record.recordID
                } else if record.recordType == CompanionStatusRecord.recordType,
                          let status = CompanionStatusRecord(record) {
                    await MainActor.run { CompanionStatusStore.shared.upsert(status) }
                }
            }
            if !commands.isEmpty {
                // applyControlCommands returns the IDs it is DONE with (applied or
                // expired). Delete those records so the one-shot command queue
                // can't accumulate / re-process on the next token reset, then
                // flush the deletes + the MacStatus ack in a single kick.
                let doneIds = await MainActor.run { self.applyControlCommands(commands) }
                let idsToDelete = doneIds.compactMap { commandRecordIDs[$0] }
                if !idsToDelete.isEmpty {
                    await MainActor.run { self.pusher?.deleteControlCommands(recordIDs: idsToDelete) }
                }
                // Never call sendChanges() inline from a delegate callback — defer
                // a detached kick that flushes both the ack and the deletes.
                Task { @MainActor [weak pusher] in
                    try? await Task.sleep(for: Self.engineRecoveryKickDelay)
                    pusher?.kickEngine()
                }
            }
            // Honor server-side deletions (e.g. a device forgotten from another
            // Mac) so a removed CompanionStatus record doesn't linger locally.
            for deletion in fetched.deletions {
                guard deletion.recordType == CompanionStatusRecord.recordType else { continue }
                let name = deletion.recordID.recordName
                let deviceId = String(name.dropFirst("CompanionStatus-".count))
                await MainActor.run { CompanionStatusStore.shared.remove(deviceId: deviceId) }
            }
            // A successful fetch proves the Mac is reaching CloudKit right now,
            // so re-stamp lastSeen (debounced) to keep the iOS reachability
            // banner honest even when no commands were pending.
            await MainActor.run { self.pusher?.touchLastSeen() }

        case .fetchedDatabaseChanges(let db):
            // Which zones the server reports as changed. If iOS wrote a
            // ControlCommand into our zone, that zone should appear here on the
            // next poll; if it never does, the poll/fetch itself isn't seeing it.
            if !db.modifications.isEmpty {
                let zones = db.modifications.map(\.zoneID.zoneName).joined(separator: ",")
                logger.notice("ckpusher.delegate: fetchedDatabaseChanges zones=[\(zones, privacy: .public)]")
            }

        case .willFetchChanges:
            logger.debug("ckpusher.delegate: willFetchChanges")
        case .didFetchChanges:
            logger.debug("ckpusher.delegate: didFetchChanges")

        case .willSendChanges, .didSendChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Batches

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await MainActor.run { self.pusher?.buildRecord(for: recordID) }
        }
    }

    // MARK: - Remote control ingestion

    /// Applies fetched ControlCommands to SleepManager (on the main actor).
    ///
    /// Ordering/idempotency: commands are sorted by `issuedAt` ascending and
    /// applied in order so the newest intent for each field wins. Dedup is by
    /// `commandId` against a bounded set of recently-applied IDs — this is
    /// clock-independent, so cross-device clock skew can never wedge delivery.
    /// The existing 10-min `isExpired` bound keeps the applied-ID set small.
    /// Commands for other Macs, expired commands, and (when the master suspend
    /// gate is off) all commands are ignored.
    /// Returns the `commandId`s the Mac is DONE with (applied, expired, or
    /// already-applied) so the caller can delete those one-shot records from the
    /// zone. Commands for OTHER Macs are left untouched.
    @MainActor
    private func applyControlCommands(_ commands: [ControlCommandRecord]) -> [String] {
        guard let pusher else { return [] }

        let ud = UserDefaults.standard
        var appliedIds = Self.loadAppliedCommandIds(ud)
        let appliedSet = Set(appliedIds)

        // Commands addressed to this Mac that are spent (expired or already
        // applied on a prior fetch) are consumable now — caller deletes them.
        let mine = commands.filter { $0.targetMacId == pusher.macId }
        var doneIds = mine
            .filter { $0.isExpired || appliedSet.contains($0.commandId) }
            .map { $0.commandId }

        let applicable = mine
            .filter { !$0.isExpired && !appliedSet.contains($0.commandId) }
            .sorted { $0.issuedAt < $1.issuedAt }

        // Audit 2026-06: when commands arrive but apply nothing, log WHY. A silent
        // `targetMacId` mismatch (iOS paired with a stale/different Mac record),
        // an expired command (clock skew), or an already-applied id each drops the
        // command with no trace — the #1 suspect for "Mac didn't respond".
        if applicable.isEmpty {
            for cmd in commands {
                let mismatch = cmd.targetMacId != pusher.macId
                let expired  = cmd.isExpired
                let dup      = appliedSet.contains(cmd.commandId)
                logger.notice("ckpusher.delegate: DROPPED \(cmd.command, privacy: .public) — targetMismatch=\(mismatch, privacy: .public)(cmd=\(cmd.targetMacId, privacy: .public) mac=\(pusher.macId, privacy: .public)) expired=\(expired, privacy: .public) alreadyApplied=\(dup, privacy: .public)")
            }
            return doneIds   // expired / already-applied records get cleaned up
        }
        logger.notice("ckpusher.delegate: applying \(applicable.count, privacy: .public) of \(commands.count, privacy: .public) fetched command(s)")

        let sm = SleepManager.shared
        var changed = false

        // Process strictly in issued order. `setMasterEnabled` bypasses the gate
        // (so it can always be turned back on); every OTHER verb is dropped while
        // the gate is off. Each command is consumed (added to the dedup ring)
        // regardless of outcome, so a dropped command never replays when the
        // gate later returns — turning master back ON must NOT resurrect stale
        // keep-awake commands.
        for cmd in applicable {
            appliedIds.append(cmd.commandId)
            doneIds.append(cmd.commandId)   // consumed → caller deletes the record

            // Connectivity diagnostic — always delivered (even while suspended)
            // and never touches SleepManager. Rings a local notification so the
            // user can confirm the iPhone reaches this Mac, then acks normally.
            if cmd.verb == .check {
                NotificationDispatcher.shared.postCheckNotification()
                ud.set(cmd.commandId, forKey: CloudKitPusher.lastAppliedCommandIdKey)
                changed = true
                logger.notice("ckpusher.delegate: applied check (rang local notification)")
                continue
            }

            if cmd.verb == .setMasterEnabled {
                guard let on = Bool(cmd.value) else { continue }
                // Local-change wins: ignore a remote master command issued before
                // the Mac user's most recent local master change.
                if let localChangedAt = ud.object(forKey: Self.masterChangedAtKey) as? Date,
                   cmd.issuedAt < localChangedAt {
                    logger.notice("ckpusher.delegate: ignoring stale remote master (older than local change)")
                    continue
                }
                ud.set(on, forKey: Self.masterEnabledKey)
                ud.set(cmd.issuedAt, forKey: Self.masterChangedAtKey)
                // CRITICAL: also set the in-memory `SleepManager.masterEnabled`
                // so its `didSet` runs (releases keep-awake on OFF, fires
                // `notifyStateChanged` for the menu-bar icon / panel). Writing
                // to UserDefaults alone is not enough — there is no cross-
                // process KVO on UserDefaults, and the same-process readers
                // (SleepManager, StatusItemController, PanelRootView) all
                // observe the in-memory property.
                sm.masterEnabled = on
                ud.set(cmd.commandId, forKey: CloudKitPusher.lastAppliedCommandIdKey)
                changed = true
                logger.notice("ckpusher.delegate: applied setMasterEnabled=\(on, privacy: .public)")
                continue
            }

            let masterOn = ud.object(forKey: Self.masterEnabledKey) as? Bool ?? true
            guard masterOn else {
                logger.notice("ckpusher.delegate: master suspended — dropping \(cmd.command, privacy: .public)")
                continue
            }

            switch cmd.verb {
            case .setKeepAwakeMode:
                guard let m = KeepAwakeMode(rawValue: cmd.value) else { continue }
                sm.keepAwakeMode = m
            case .setScreenMode:
                guard let s = DoomCoderMode(rawValue: cmd.value) else { continue }
                sm.mode = s
            case .setSessionTimerHours:
                guard let raw = Int(cmd.value) else { continue }
                sm.sessionTimerHours = max(0, min(raw, 24))   // clamp to a sane range
            case .setSnooze:
                // v2.6 — Auto-mode snooze override. Empty value = cancel.
                if cmd.value.isEmpty {
                    sm.cancelSnooze()
                } else if let d = SnoozeDuration(rawValue: cmd.value) {
                    sm.snooze(d)
                } else {
                    continue
                }
            case .setMasterEnabled, .check, .none:
                // setMasterEnabled + check are handled in the always-deliver
                // region above; reaching here means they were already consumed.
                continue
            }
            ud.set(cmd.commandId, forKey: CloudKitPusher.lastAppliedCommandIdKey)
            changed = true
            logger.notice("ckpusher.delegate: applied \(cmd.command, privacy: .public)=\(cmd.value, privacy: .public)")
        }

        // Persist the bounded applied-ID ring (keeps the most recent N).
        Self.saveAppliedCommandIds(appliedIds, ud)

        if changed {
            ud.set(Date(), forKey: CloudKitPusher.lastAppliedAtKey)
            // Queue a fresh MacStatus carrying the ack fields. The caller flushes
            // this together with the command-record deletes in one deferred kick
            // (never call sendChanges() inline from a delegate callback).
            pusher.touchLastSeen(force: true)
        }
        return doneIds
    }

    /// UserDefaults keys for the app-wide master suspend gate. Shared with
    /// PanelRootView's `@AppStorage` and the local-change-wins comparison.
    static let masterEnabledKey = "doomcoder.masterEnabled"
    static let masterChangedAtKey = "doomcoder.masterEnabledChangedAt"

    /// Bounded set of recently-applied command IDs (clock-independent dedup).
    private static let appliedCommandIdsKey = "doomcoder.ckpusher.appliedCommandIds"
    private static let maxAppliedCommandIds = 50

    private static func loadAppliedCommandIds(_ ud: UserDefaults) -> [String] {
        ud.stringArray(forKey: appliedCommandIdsKey) ?? []
    }

    private static func saveAppliedCommandIds(_ ids: [String], _ ud: UserDefaults) {
        let trimmed = Array(ids.suffix(maxAppliedCommandIds))
        ud.set(trimmed, forKey: appliedCommandIdsKey)
    }

    // MARK: - State persistence

    @MainActor
    private func persistState(_ state: CKSyncEngine.State.Serialization) {
        // Audit 2026-06: respect cancellation before doing the encode +
        // write. If the engine is being torn down (Phase 1.10's `stop()`),
        // we don't want to write a state that no one will read. JSON
        // encode of a CKSyncEngine state is ~10-50 KB; the UserDefaults
        // write triggers a disk flush. Both are cheap but a cancellation
        // check is the polite thing to do.
        guard !Task.isCancelled else { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }
}

// MARK: - Companion presence store

/// Mac-side store of companion-device presence. The iOS/iPadOS companion writes
/// a `CompanionStatusRecord` heartbeat; this Mac fetches it via the push
/// pipeline's `CKSyncEngine` and upserts here so Configure ▸ Connections can
/// show real connected/unreachable status per device — symmetric to how the
/// companion shows the Mac's status.
@MainActor
@Observable
final class CompanionStatusStore {

    static let shared = CompanionStatusStore()

    /// Devices keyed by stable `deviceId`.
    private(set) var byDevice: [String: CompanionStatusRecord] = [:]

    /// All known devices, most-recently-seen first.
    var devices: [CompanionStatusRecord] {
        byDevice.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// True when at least one device has checked in within the freshness window.
    var hasConnectedDevice: Bool {
        let now = Date()
        return byDevice.values.contains { now.timeIntervalSince($0.lastSeen) < Self.connectedThreshold }
    }

    /// Mirrors the companion's 600 s reachability rule so both sides agree.
    static let connectedThreshold: TimeInterval = 600

    private static let persistKey = "doomcoder.companion.statusSnapshot"

    private init() {
        load()
    }

    func upsert(_ record: CompanionStatusRecord) {
        // Keep the freshest heartbeat if records arrive out of order.
        if let existing = byDevice[record.deviceId], existing.lastSeen > record.lastSeen { return }
        byDevice[record.deviceId] = record
        persist()
    }

    func clear() {
        byDevice.removeAll()
        persist()
    }

    /// Drops a single device locally (used by "Forget device" after the CloudKit
    /// record delete is queued). A still-alive device re-registers on its next
    /// heartbeat, which is the correct, self-healing behavior.
    func remove(deviceId: String) {
        byDevice.removeValue(forKey: deviceId)
        persist()
    }

    private func persist() {
        let snapshot = Array(byDevice.values)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistKey),
              let snapshot = try? JSONDecoder().decode([CompanionStatusRecord].self, from: data)
        else { return }
        for record in snapshot { byDevice[record.deviceId] = record }
    }
}
