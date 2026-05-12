import Foundation
import CloudKit
import Combine

@MainActor
final class IOSUserSettings: ObservableObject {
    static let shared = IOSUserSettings()
    @Published var minimalMode: Bool = false
    @Published var notifyApprovals: Bool = true
    @Published var notifyFailures: Bool = true
    @Published var notifySessionSummaries: Bool = true
    @Published var notifyToolCallUpdates: Bool = false
    @Published var liveActivityMaxConcurrent: Int = 3
    @Published var liveActivityAutoDismissSec: Int = 30
    @Published var historyRetentionDays: Int = 7
    @Published var lastModifiedBy: String = ""
    @Published var lastModifiedAt: Date = .distantPast

    private init() { load() }

    private func load() {
        let d = UserDefaults.standard
        if d.object(forKey: "settings.minimalMode") != nil { minimalMode = d.bool(forKey: "settings.minimalMode") }
        if d.object(forKey: "settings.notifyApprovals") != nil { notifyApprovals = d.bool(forKey: "settings.notifyApprovals") }
        if d.object(forKey: "settings.notifyFailures") != nil { notifyFailures = d.bool(forKey: "settings.notifyFailures") }
        if d.object(forKey: "settings.notifySessionSummaries") != nil { notifySessionSummaries = d.bool(forKey: "settings.notifySessionSummaries") }
        if d.object(forKey: "settings.notifyToolCallUpdates") != nil { notifyToolCallUpdates = d.bool(forKey: "settings.notifyToolCallUpdates") }
        if d.object(forKey: "settings.liveActivityMaxConcurrent") != nil { liveActivityMaxConcurrent = d.integer(forKey: "settings.liveActivityMaxConcurrent") }
        if d.object(forKey: "settings.liveActivityAutoDismissSec") != nil { liveActivityAutoDismissSec = d.integer(forKey: "settings.liveActivityAutoDismissSec") }
        if d.object(forKey: "settings.historyRetentionDays") != nil { historyRetentionDays = d.integer(forKey: "settings.historyRetentionDays") }
    }

    func persistLocal() {
        let d = UserDefaults.standard
        d.set(minimalMode, forKey: "settings.minimalMode")
        d.set(notifyApprovals, forKey: "settings.notifyApprovals")
        d.set(notifyFailures, forKey: "settings.notifyFailures")
        d.set(notifySessionSummaries, forKey: "settings.notifySessionSummaries")
        d.set(notifyToolCallUpdates, forKey: "settings.notifyToolCallUpdates")
        d.set(liveActivityMaxConcurrent, forKey: "settings.liveActivityMaxConcurrent")
        d.set(liveActivityAutoDismissSec, forKey: "settings.liveActivityAutoDismissSec")
        d.set(historyRetentionDays, forKey: "settings.historyRetentionDays")
    }
}

@MainActor
final class SettingsSyncer {
    static let shared = SettingsSyncer()
    private let recordId = CKRecord.ID(recordName: "settings")
    private var debounceTask: Task<Void, Never>?
    private init() {}

    func pull() async {
        do {
            guard let rec = try await CloudKitClient.shared.record(for: recordId) else { return }
            applyRemote(rec)
        } catch let err as CKError where err.code == .unknownItem {
            await pushLocal()
        } catch {
            // network/transient — try later
        }
    }

    func applyRemote(_ rec: CKRecord) {
        let s = IOSUserSettings.shared
        let remoteTs = (rec["lastModifiedAt"] as? Date) ?? .distantPast
        let remoteDevice = (rec["lastModifiedBy"] as? String) ?? ""
        let myUUID = DevicePresenceUpdater.shared.deviceUUID()
        if remoteDevice == myUUID && remoteTs <= s.lastModifiedAt { return }
        if let v = rec["minimalMode"] as? Int { s.minimalMode = v != 0 }
        if let v = rec["notifyApprovals"] as? Int { s.notifyApprovals = v != 0 }
        if let v = rec["notifyFailures"] as? Int { s.notifyFailures = v != 0 }
        if let v = rec["notifySessionSummaries"] as? Int { s.notifySessionSummaries = v != 0 }
        if let v = rec["notifyToolCallUpdates"] as? Int { s.notifyToolCallUpdates = v != 0 }
        if let v = rec["liveActivityMaxConcurrent"] as? Int { s.liveActivityMaxConcurrent = v }
        if let v = rec["liveActivityAutoDismissSec"] as? Int { s.liveActivityAutoDismissSec = v }
        if let v = rec["historyRetentionDays"] as? Int { s.historyRetentionDays = v }
        s.lastModifiedAt = remoteTs
        s.lastModifiedBy = remoteDevice
        s.persistLocal()
    }

    func scheduleLocalPush() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushLocal()
        }
    }

    func pushLocal() async {
        let s = IOSUserSettings.shared
        s.persistLocal()
        let now = Date()
        let myUUID = DevicePresenceUpdater.shared.deviceUUID()
        let rec: CKRecord
        do {
            rec = try await CloudKitClient.shared.record(for: recordId) ?? CKRecord(recordType: CloudKitSchema.RecordType.userSettings, recordID: recordId)
        } catch {
            rec = CKRecord(recordType: CloudKitSchema.RecordType.userSettings, recordID: recordId)
        }
        rec["minimalMode"] = (s.minimalMode ? 1 : 0) as CKRecordValue
        rec["notifyApprovals"] = (s.notifyApprovals ? 1 : 0) as CKRecordValue
        rec["notifyFailures"] = (s.notifyFailures ? 1 : 0) as CKRecordValue
        rec["notifySessionSummaries"] = (s.notifySessionSummaries ? 1 : 0) as CKRecordValue
        rec["notifyToolCallUpdates"] = (s.notifyToolCallUpdates ? 1 : 0) as CKRecordValue
        rec["liveActivityMaxConcurrent"] = s.liveActivityMaxConcurrent as CKRecordValue
        rec["liveActivityAutoDismissSec"] = s.liveActivityAutoDismissSec as CKRecordValue
        rec["historyRetentionDays"] = s.historyRetentionDays as CKRecordValue
        rec["lastModifiedBy"] = myUUID as CKRecordValue
        rec["lastModifiedAt"] = now as CKRecordValue
        do {
            _ = try await CloudKitClient.shared.save(rec)
            s.lastModifiedAt = now
            s.lastModifiedBy = myUUID
        } catch {
            // retry on next change
        }
    }
}
