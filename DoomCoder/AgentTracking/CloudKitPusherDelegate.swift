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

        // Respect the local master suspend gate — remote control must not
        // override an explicit "suspend everything" on the Mac.
        let masterOn = UserDefaults.standard.object(forKey: "doomcoder.masterEnabled") as? Bool ?? true
        guard masterOn else {
            logger.notice("ckpusher.delegate: master suspended — ignoring \(commands.count, privacy: .public) remote command(s)")
            return
        }

        let ud = UserDefaults.standard
        var appliedIds = Self.loadAppliedCommandIds(ud)
        let appliedSet = Set(appliedIds)

        let applicable = commands
            .filter { $0.targetMacId == pusher.macId && !$0.isExpired && !appliedSet.contains($0.commandId) }
            .sorted { $0.issuedAt < $1.issuedAt }

        guard !applicable.isEmpty else { return }

        let sm = SleepManager.shared
        var changed = false
        for cmd in applicable {
            // Mark as seen first so an unknown/invalid command is never
            // reprocessed on every subsequent fetch.
            appliedIds.append(cmd.commandId)
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
            case .none:
                logger.notice("ckpusher.delegate: unknown command verb \(cmd.command, privacy: .public)")
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
        // Publish fresh status so iOS confirms the command(s) landed.
        pusher.publishMacStatus()
    }

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
