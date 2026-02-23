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
    /// applied in order so the newest intent for each field wins. A persisted
    /// high-water `issuedAt` plus the last-applied `commandId` ensure a command
    /// re-fetched after a newer one (or after a state reset) is never re-applied.
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
        let lastId = ud.string(forKey: CloudKitPusher.lastAppliedCommandIdKey)
        let highWater = (ud.object(forKey: Self.lastAppliedIssuedAtKey) as? Date) ?? .distantPast

        let applicable = commands
            .filter { $0.targetMacId == pusher.macId && !$0.isExpired }
            .filter { $0.issuedAt > highWater && $0.commandId != lastId }
            .sorted { $0.issuedAt < $1.issuedAt }

        guard !applicable.isEmpty else { return }

        let sm = SleepManager.shared
        var applied = false
        for cmd in applicable {
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
            ud.set(cmd.issuedAt, forKey: Self.lastAppliedIssuedAtKey)
            applied = true
            logger.notice("ckpusher.delegate: applied \(cmd.command, privacy: .public)=\(cmd.value, privacy: .public)")
        }

        guard applied else { return }
        ud.set(Date(), forKey: CloudKitPusher.lastAppliedAtKey)
        // Publish fresh status so iOS confirms the command(s) landed.
        pusher.publishMacStatus()
    }

    /// High-water mark for the most recent applied command's `issuedAt`.
    private static let lastAppliedIssuedAtKey = "doomcoder.ckpusher.lastAppliedIssuedAt"

    // MARK: - State persistence

    @MainActor
    private func persistState(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }
}
