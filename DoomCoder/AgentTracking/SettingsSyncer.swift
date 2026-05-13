import CloudKit
import Foundation
import OSLog

// MARK: - SettingsSyncer (macOS)

/// Mirrors local `UserSettings` to/from the CloudKit `CKUserSettings` record,
/// providing bidirectional cross-device sync. Last-write-wins on lastModifiedAt.
///
/// On Mac, this watches local `UserDefaults` mutations and writes a single
/// shared record. On iOS, the matching syncer subscribes via CK push.
@MainActor
final class SettingsSyncer {
    static let shared = SettingsSyncer()

    private let logger = Logger(subsystem: "com.doomcoder", category: "settings-sync")
    private let container: CKContainer
    private let db: CKDatabase
    private var lastPushAt: Date = .distantPast
    private let minPushInterval: TimeInterval = 1.0
    private var pending: Task<Void, Never>?
    private var sleepPollTask: Task<Void, Never>?
    private var lastSleepCommandCheckAt: Date = .distantPast

    private init() {
        container = CKContainer(identifier: CloudKitSchema.containerIdentifier)
        db = container.privateCloudDatabase
    }

    func pushLocal() {
        guard FeatureFlags.cloudKitEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPushAt) >= minPushInterval else {
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.pushLocal()
            }
            return
        }
        lastPushAt = now
        let settings = currentLocal()
        Task { await self.upload(settings) }
    }

    func pull() async {
        guard FeatureFlags.cloudKitEnabled else { return }
        let rid = CKRecord.ID(recordName: "settings")
        await withCheckedContinuation { cont in
            db.fetch(withRecordID: rid) { rec, _ in
                if let rec, let s = Self.decode(rec) {
                    Task { @MainActor in
                        self.applyRemote(s)
                        cont.resume()
                    }
                } else {
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Sleep sync

    func startSleepSync() {
        guard sleepPollTask == nil else { return }
        sleepPollTask = Task { @MainActor in
            while !Task.isCancelled {
                await pushSleepState()
                await pollSleepCommands()
                try? await Task.sleep(for: .seconds(DoomCoderConstants.sleepSyncIntervalSeconds))
            }
        }
    }

    func pushSleepState() async {
        let sm = SleepManager.shared
        let rid = CKRecord.ID(recordName: "settings")
        let rec = CKRecord(recordType: CloudKitSchema.RecordType.userSettings, recordID: rid)
        rec["sleepEnabled"] = (sm.isActive ? 1 : 0) as CKRecordValue
        rec["sleepMode"] = sm.mode.rawValue as CKRecordValue
        rec["sleepElapsedSec"] = sm.elapsedSeconds as CKRecordValue
        rec["sleepScreenOffRearmMinutes"] = sm.screenOffRearmMinutes as CKRecordValue
        rec["sleepSessionTimerHours"] = sm.sessionTimerHours as CKRecordValue
        rec["sleepThermalState"] = sm.thermalStateText as CKRecordValue
        let op = CKModifyRecordsOperation(recordsToSave: [rec], recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        op.modifyRecordsResultBlock = { _ in }
        db.add(op)
    }

    private func pollSleepCommands() async {
        let since = lastSleepCommandCheckAt
        lastSleepCommandCheckAt = Date()
        let pred = NSPredicate(format: "issuedAt > %@", since as CVarArg)
        let q = CKQuery(recordType: CloudKitSchema.RecordType.sleepCommand, predicate: pred)
        let (results, _) = (try? await db.records(matching: q, resultsLimit: 10)) ?? ([], nil)
        var toDelete: [CKRecord.ID] = []
        for (_, res) in results {
            if case .success(let rec) = res {
                applySleepCommand(rec)
                toDelete.append(rec.recordID)
            }
        }
        if !toDelete.isEmpty {
            let deleteOp = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: toDelete)
            db.add(deleteOp)
        }
    }

    private func applySleepCommand(_ rec: CKRecord) {
        let sm = SleepManager.shared
        let type = rec["commandType"] as? String ?? ""
        switch type {
        case "toggle":
            let on = (rec["enabled"] as? Int ?? 0) != 0
            if on { sm.enable() } else { sm.disable() }
        case "setMode":
            if let modeStr = rec["mode"] as? String,
               let mode = DoomCoderMode(rawValue: modeStr) {
                sm.mode = mode
            }
        case "setRearmMinutes":
            if let v = rec["rearmMinutes"] as? Int { sm.screenOffRearmMinutes = v }
        case "setTimerHours":
            if let v = rec["timerHours"] as? Int { sm.sessionTimerHours = v }
        default: break
        }
    }

    private func currentLocal() -> CKUserSettings {
        let d = UserDefaults.standard
        return CKUserSettings(
            minimalMode: FeatureFlags.minimalMode,
            notifyApprovals: d.object(forKey: "settings.notifyApprovals") as? Bool ?? true,
            notifyFailures: d.object(forKey: "settings.notifyFailures") as? Bool ?? true,
            notifySessionSummaries: d.object(forKey: "settings.notifySessionSummaries") as? Bool ?? true,
            notifyToolCallUpdates: d.object(forKey: "settings.notifyToolCallUpdates") as? Bool ?? false,
            liveActivityMaxConcurrent: d.object(forKey: "settings.liveActivityMaxConcurrent") as? Int ?? 3,
            liveActivityAutoDismissSec: d.object(forKey: "settings.liveActivityAutoDismissSec") as? Int ?? 30,
            historyRetentionDays: d.object(forKey: "settings.historyRetentionDays") as? Int ?? 7,
            lastModifiedBy: ProcessInfo.processInfo.hostName,
            lastModifiedAt: Date()
        )
    }

    private func applyRemote(_ s: CKUserSettings) {
        let d = UserDefaults.standard
        FeatureFlags.minimalMode = s.minimalMode
        d.set(s.notifyApprovals, forKey: "settings.notifyApprovals")
        d.set(s.notifyFailures, forKey: "settings.notifyFailures")
        d.set(s.notifySessionSummaries, forKey: "settings.notifySessionSummaries")
        d.set(s.notifyToolCallUpdates, forKey: "settings.notifyToolCallUpdates")
        d.set(s.liveActivityMaxConcurrent, forKey: "settings.liveActivityMaxConcurrent")
        d.set(s.liveActivityAutoDismissSec, forKey: "settings.liveActivityAutoDismissSec")
        d.set(s.historyRetentionDays, forKey: "settings.historyRetentionDays")
    }

    private func upload(_ s: CKUserSettings) async {
        let rid = CKRecord.ID(recordName: s.recordName)
        let rec = CKRecord(recordType: CloudKitSchema.RecordType.userSettings, recordID: rid)
        rec["minimalMode"] = s.minimalMode as CKRecordValue
        rec["notifyApprovals"] = s.notifyApprovals as CKRecordValue
        rec["notifyFailures"] = s.notifyFailures as CKRecordValue
        rec["notifySessionSummaries"] = s.notifySessionSummaries as CKRecordValue
        rec["notifyToolCallUpdates"] = s.notifyToolCallUpdates as CKRecordValue
        rec["liveActivityMaxConcurrent"] = s.liveActivityMaxConcurrent as CKRecordValue
        rec["liveActivityAutoDismissSec"] = s.liveActivityAutoDismissSec as CKRecordValue
        rec["historyRetentionDays"] = s.historyRetentionDays as CKRecordValue
        rec["lastModifiedBy"] = s.lastModifiedBy as CKRecordValue
        rec["lastModifiedAt"] = s.lastModifiedAt as CKRecordValue

        await withCheckedContinuation { cont in
            let op = CKModifyRecordsOperation(recordsToSave: [rec], recordIDsToDelete: nil)
            op.savePolicy = .changedKeys
            op.modifyRecordsResultBlock = { _ in cont.resume() }
            db.add(op)
        }
    }

    nonisolated static func decode(_ rec: CKRecord) -> CKUserSettings? {
        guard rec.recordType == CloudKitSchema.RecordType.userSettings else { return nil }
        guard let by = rec["lastModifiedBy"] as? String,
              let at = rec["lastModifiedAt"] as? Date else { return nil }
        return CKUserSettings(
            minimalMode: (rec["minimalMode"] as? Bool) ?? false,
            notifyApprovals: (rec["notifyApprovals"] as? Bool) ?? true,
            notifyFailures: (rec["notifyFailures"] as? Bool) ?? true,
            notifySessionSummaries: (rec["notifySessionSummaries"] as? Bool) ?? true,
            notifyToolCallUpdates: (rec["notifyToolCallUpdates"] as? Bool) ?? false,
            liveActivityMaxConcurrent: (rec["liveActivityMaxConcurrent"] as? Int) ?? 3,
            liveActivityAutoDismissSec: (rec["liveActivityAutoDismissSec"] as? Int) ?? 30,
            historyRetentionDays: (rec["historyRetentionDays"] as? Int) ?? 7,
            lastModifiedBy: by,
            lastModifiedAt: at
        )
    }
}
