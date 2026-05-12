import Foundation
import CloudKit

@MainActor
final class CloudKitClient {
    static let shared = CloudKitClient()
    let container = CKContainer(identifier: CloudKitSchema.containerIdentifier)
    var db: CKDatabase { container.privateCloudDatabase }
    private init() {}

    func fetchActiveSessions() async throws -> [CKSessionAggregate] {
        let predicate = NSPredicate(format: "status IN %@", ["running", "waitingApproval"])
        return try await query(recordType: CloudKitSchema.RecordType.sessionAggregate,
                               predicate: predicate,
                               sortKey: "lastEventAt")
    }

    func fetchHistory(daysBack: Int = 7) async throws -> [CKSessionAggregate] {
        let cutoff = Date().addingTimeInterval(-Double(daysBack) * 86_400)
        let predicate = NSPredicate(format: "lastEventAt >= %@", cutoff as NSDate)
        return try await query(recordType: CloudKitSchema.RecordType.sessionAggregate,
                               predicate: predicate,
                               sortKey: "lastEventAt")
    }

    func fetchAggregate(sessionKey: String) async throws -> CKSessionAggregate? {
        let id = CKRecord.ID(recordName: sessionKey)
        let record = try await db.record(for: id)
        return decodeAggregate(record)
    }

    func fetchEvents(sessionKey: String) async throws -> [CKAgentEvent] {
        let predicate = NSPredicate(format: "sessionKey == %@", sessionKey)
        return try await query(recordType: CloudKitSchema.RecordType.agentEvent,
                               predicate: predicate,
                               sortKey: "occurredAt",
                               ascending: true)
    }

    func writeApprovalResponse(requestId: String, decision: String, deviceUUID: String) async throws {
        let id = CKRecord.ID(recordName: requestId)
        let rec = CKRecord(recordType: CloudKitSchema.RecordType.approvalResponse, recordID: id)
        rec["requestId"] = requestId as CKRecordValue
        rec["decision"] = decision as CKRecordValue
        rec["decidedAt"] = Date() as CKRecordValue
        rec["decidedByDevice"] = deviceUUID as CKRecordValue
        _ = try await db.save(rec)
    }

    func writeDevicePresence(uuid: String, name: String, appVersion: String) async throws {
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
            db.add(op)
        }
    }

    private func query<T>(recordType: String,
                          predicate: NSPredicate,
                          sortKey: String?,
                          ascending: Bool = false) async throws -> [T] where T == CKSessionAggregate {
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

    private func query<T>(recordType: String,
                          predicate: NSPredicate,
                          sortKey: String?,
                          ascending: Bool = false) async throws -> [T] where T == CKAgentEvent {
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
            expiresAt: (rec["expiresAt"] as? Date) ?? Date().addingTimeInterval(7 * 86400)
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
