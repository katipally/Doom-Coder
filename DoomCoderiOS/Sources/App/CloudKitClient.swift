import Foundation
import CloudKit

@MainActor
final class CloudKitClient {
    static let shared = CloudKitClient()

    // Nil in XCTest — CKContainer(identifier:) and .default() both throw
    // NSExceptions in the iOS Simulator when CODE_SIGNING_ALLOWED=NO.
    private let _container: CKContainer?
    private var db: CKDatabase { _container!.privateCloudDatabase }

    var container: CKContainer? { _container }

    func accountStatus() async -> CKAccountStatus {
        guard let c = _container else { return .noAccount }
        return (try? await c.accountStatus()) ?? .couldNotDetermine
    }

    func fetchMacPresenceCount() async -> Int {
        guard let c = _container else { return 0 }
        let pred = NSPredicate(format: "platform == %@", "macOS")
        let q = CKQuery(recordType: CloudKitSchema.RecordType.devicePresence, predicate: pred)
        let (results, _) = (try? await c.privateCloudDatabase.records(matching: q, resultsLimit: 50)) ?? ([], nil)
        return results.count
    }

    private init() {
        let isTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        _container = isTest ? nil : CKContainer(identifier: CloudKitSchema.containerIdentifier)
    }

    func fetchActiveSessions() async throws -> [CKSessionAggregate] {
        guard _container != nil else { return [] }
        let predicate = NSPredicate(format: "status IN %@", ["running", "waitingApproval"])
        return try await queryAggregates(recordType: CloudKitSchema.RecordType.sessionAggregate,
                               predicate: predicate,
                               sortKey: "lastEventAt")
    }

    func fetchHistory(daysBack: Int = 7) async throws -> [CKSessionAggregate] {
        guard _container != nil else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(daysBack) * 86_400)
        let predicate = NSPredicate(format: "lastEventAt >= %@", cutoff as NSDate)
        return try await queryAggregates(recordType: CloudKitSchema.RecordType.sessionAggregate,
                               predicate: predicate,
                               sortKey: "lastEventAt")
    }

    func fetchAggregate(sessionKey: String) async throws -> CKSessionAggregate? {
        guard _container != nil else { return nil }
        let id = CKRecord.ID(recordName: sessionKey)
        let record = try await db.record(for: id)
        return decodeAggregate(record)
    }

    func record(for id: CKRecord.ID) async throws -> CKRecord? {
        guard let c = _container else { return nil }
        return try await c.privateCloudDatabase.record(for: id)
    }

    @discardableResult
    func save(_ record: CKRecord) async throws -> CKRecord? {
        guard let c = _container else { return nil }
        return try await c.privateCloudDatabase.save(record)
    }

    func modifySubscriptions(saving: [CKSubscription]) async throws {
        guard let c = _container else { return }
        _ = try await c.privateCloudDatabase.modifySubscriptions(saving: saving, deleting: [])
    }

    func fetchEvents(sessionKey: String) async throws -> [CKAgentEvent] {
        guard _container != nil else { return [] }
        let predicate = NSPredicate(format: "sessionKey == %@", sessionKey)
        return try await queryEvents(recordType: CloudKitSchema.RecordType.agentEvent,
                               predicate: predicate,
                               sortKey: "occurredAt",
                               ascending: true)
    }

    func writeApprovalResponse(requestId: String, decision: String, deviceUUID: String) async throws {
        guard _container != nil else { return }
        let id = CKRecord.ID(recordName: requestId)
        let rec = CKRecord(recordType: CloudKitSchema.RecordType.approvalResponse, recordID: id)
        rec["requestId"] = requestId as CKRecordValue
        rec["decision"] = decision as CKRecordValue
        rec["decidedAt"] = Date() as CKRecordValue
        rec["decidedByDevice"] = deviceUUID as CKRecordValue
        _ = try await db.save(rec)
    }

    func writeSleepCommand(type: String, enabled: Bool? = nil, mode: String? = nil,
                           rearmMinutes: Int? = nil, timerHours: Int? = nil) async throws {
        let commandId = UUID().uuidString
        let id = CKRecord.ID(recordName: commandId)
        let rec = CKRecord(recordType: CloudKitSchema.RecordType.sleepCommand, recordID: id)
        rec["commandId"] = commandId as CKRecordValue
        rec["commandType"] = type as CKRecordValue
        let now = Date()
        rec["issuedAt"] = now as CKRecordValue
        rec["expiresAt"] = now.addingTimeInterval(300) as CKRecordValue  // 5 min TTL
        if let v = enabled { rec["enabled"] = (v ? 1 : 0) as CKRecordValue }
        if let v = mode { rec["mode"] = v as CKRecordValue }
        if let v = rearmMinutes { rec["rearmMinutes"] = v as CKRecordValue }
        if let v = timerHours { rec["timerHours"] = v as CKRecordValue }
        _ = try await db.save(rec)
    }

    func writeDevicePresence(uuid: String, name: String, appVersion: String) async throws {
        guard let container = _container else { return }
        let id = CKRecord.ID(recordName: uuid)
        let rec = CKRecord(recordType: CloudKitSchema.RecordType.devicePresence, recordID: id)
        rec["deviceUUID"] = uuid as CKRecordValue
        rec["deviceName"] = name as CKRecordValue
        rec["platform"] = "iOS" as CKRecordValue
        rec["appVersion"] = appVersion as CKRecordValue
        rec["lastSeenAt"] = Date() as CKRecordValue
        let op = CKModifyRecordsOperation(recordsToSave: [rec], recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        op.qualityOfService = .userInitiated
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            container.privateCloudDatabase.add(op)
        }
    }

    private func queryAggregates(recordType: String,
                          predicate: NSPredicate,
                          sortKey: String?,
                          ascending: Bool = false) async throws -> [CKSessionAggregate] {
        let q = CKQuery(recordType: recordType, predicate: predicate)
        if let sortKey { q.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)] }
        let (matchResults, _) = try await db.records(matching: q, resultsLimit: 200)
        var out: [CKSessionAggregate] = []
        for (_, res) in matchResults {
            if case .success(let rec) = res, let a = decodeAggregate(rec) {
                out.append(a)
            }
        }
        return out
    }

    private func queryEvents(recordType: String,
                          predicate: NSPredicate,
                          sortKey: String?,
                          ascending: Bool = false) async throws -> [CKAgentEvent] {
        let q = CKQuery(recordType: recordType, predicate: predicate)
        if let sortKey { q.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)] }
        let (matchResults, _) = try await db.records(matching: q, resultsLimit: 500)
        var out: [CKAgentEvent] = []
        for (_, res) in matchResults {
            if case .success(let rec) = res, let e = decodeEvent(rec) {
                out.append(e)
            }
        }
        return out
    }

    private func decodeAggregate(_ rec: CKRecord) -> CKSessionAggregate? {
        guard let sessionKey = rec["sessionKey"] as? String,
              let agent = rec["agent"] as? String,
              let macHostname = rec["macHostname"] as? String,
              let cwdBasename = rec["cwdBasename"] as? String,
              let startedAt = rec["startedAt"] as? Date,
              let lastEventAt = rec["lastEventAt"] as? Date,
              let statusRaw = rec["status"] as? String,
              let status = CKSessionAggregate.Status(rawValue: statusRaw) else { return nil }
        return CKSessionAggregate(
            sessionKey: sessionKey,
            agent: agent,
            agentVariant: rec["agentVariant"] as? String,
            macHostname: macHostname,
            cwdBasename: cwdBasename,
            cwdHashSuffix: (rec["cwdHashSuffix"] as? String) ?? "",
            startedAt: startedAt,
            lastEventAt: lastEventAt,
            endedAt: rec["endedAt"] as? Date,
            status: status,
            currentTool: rec["currentTool"] as? String,
            totalToolCalls: (rec["totalToolCalls"] as? Int) ?? 0,
            totalFilesEdited: (rec["totalFilesEdited"] as? Int) ?? 0,
            totalErrors: (rec["totalErrors"] as? Int) ?? 0,
            model: rec["model"] as? String,
            promptPreview: rec["promptPreview"] as? String,
            expiresAt: (rec["expiresAt"] as? Date) ?? Date().addingTimeInterval(7 * 86400),
            pendingRequestId: rec["pendingRequestId"] as? String
        )
    }

    private func decodeEvent(_ rec: CKRecord) -> CKAgentEvent? {
        guard let sessionKey = rec["sessionKey"] as? String,
              let agent = rec["agent"] as? String,
              let macHostname = rec["macHostname"] as? String,
              let cwdBasename = rec["cwdBasename"] as? String,
              let hookPhase = rec["hookPhase"] as? String,
              let occurredAt = rec["occurredAt"] as? Date,
              let payloadJSON = rec["payloadJSON"] as? String else { return nil }
        return CKAgentEvent(
            sessionKey: sessionKey,
            agent: agent,
            agentVariant: rec["agentVariant"] as? String,
            macHostname: macHostname,
            cwdBasename: cwdBasename,
            cwdHashSuffix: (rec["cwdHashSuffix"] as? String) ?? "",
            hookPhase: hookPhase,
            occurredAt: occurredAt,
            payloadJSON: payloadJSON,
            expiresAt: (rec["expiresAt"] as? Date) ?? Date().addingTimeInterval(7 * 86400)
        )
    }
}
