// CloudKitPusherDelegate.swift
//
// CKSyncEngineDelegate for the Mac push-only pipeline.

import Foundation
import CloudKit
import OSLog
import Observation
import DoomCodeCore

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
            var commands: [ControlCommandRecord] = []
            for mod in fetched.modifications {
                let record = mod.record
                await MainActor.run { self.pusher?.serverRecords.store(record) }
                if record.recordType == ControlCommandRecord.recordType,
                   let cmd = ControlCommandRecord(record) {
                    commands.append(cmd)
                } else if record.recordType == CompanionStatusRecord.recordType,
                          let status = CompanionStatusRecord(record) {
                    await MainActor.run { CompanionStatusStore.shared.upsert(status) }
                }
            }
            if !commands.isEmpty {
                await MainActor.run { self.applyControlCommands(commands) }
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

        case .willSendChanges, .didSendChanges,
             .willFetchChanges, .didFetchChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .fetchedDatabaseChanges:
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
    @MainActor
    private func applyControlCommands(_ commands: [ControlCommandRecord]) {
        guard let pusher else { return }

        let ud = UserDefaults.standard
        var appliedIds = Self.loadAppliedCommandIds(ud)
        let appliedSet = Set(appliedIds)

        let applicable = commands
            .filter { $0.targetMacId == pusher.macId && !$0.isExpired && !appliedSet.contains($0.commandId) }
            .sorted { $0.issuedAt < $1.issuedAt }

        guard !applicable.isEmpty else { return }

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
                // Turning OFF releases any keep-awake assertion. Turning ON does
                // NOT force keep-awake — the Off/On/Auto selector owns that.
                if !on { sm.disable() }
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
                guard let s = DoomCodeMode(rawValue: cmd.value) else { continue }
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

        guard changed else { return }
        ud.set(Date(), forKey: CloudKitPusher.lastAppliedAtKey)
        // Queue a fresh MacStatus with the ack fields.
        pusher.touchLastSeen(force: true)
        // Flush the queued record immediately via a new Task — must NOT be
        // an inline await (calling sendChanges() re-entrantly from a delegate
        // callback is a CloudKit misuse). The brief delay lets the engine
        // finish processing the current fetch before we trigger a send.
        Task { @MainActor [weak pusher] in
            try? await Task.sleep(for: Self.engineRecoveryKickDelay)
            pusher?.kickEngine()
        }
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
