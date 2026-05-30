// CloudKitPusherDelegate.swift
//
// CKSyncEngineDelegate for the Mac push-only pipeline.

import Foundation
import CloudKit
import OSLog
import DoomCoderCore

final class CloudKitPusherDelegate: NSObject, CKSyncEngineDelegate, @unchecked Sendable {

    private let logger = Logger(subsystem: "com.doomcoder", category: "ckpusher.delegate")
    private weak var pusher: CloudKitPusher?
    private let stateKey: String

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
            for failed in sent.failedRecordSaves {
                let code = failed.error.code
                logger.error("ckpusher.delegate: failed save \(failed.record.recordID.recordName, privacy: .public) code=\(String(describing: code), privacy: .public)")
                if let serverRec = failed.error.serverRecord {
                    await MainActor.run { self.pusher?.serverRecords.store(serverRec) }
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
                }
            }
            if !commands.isEmpty {
                await MainActor.run { self.applyControlCommands(commands) }
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
                guard let s = DoomCoderMode(rawValue: cmd.value) else { continue }
                sm.mode = s
            case .setSessionTimerHours:
                guard let raw = Int(cmd.value) else { continue }
                sm.sessionTimerHours = max(0, min(raw, 24))   // clamp to a sane range
            case .setMasterEnabled, .none:
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
        // Publish fresh status AND flush it immediately so iOS confirms the
        // command(s) landed without waiting for the next safety-net send.
        pusher.touchLastSeen(force: true)
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
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }
}
