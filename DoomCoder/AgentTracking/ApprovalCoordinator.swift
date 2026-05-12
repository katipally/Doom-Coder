import CloudKit
import Foundation
import OSLog

/// Handles dc-hook waitable approvals (Phase 4). For each envelope flagged
/// `wantsBlockingReply=true`, publishes a `CKApprovalRequest` and polls
/// `CKApprovalResponse` until a decision arrives or timeout. The decision is
/// written to `~/Library/Application Support/DoomCoder/approvals/<requestId>.json`
/// which dc-hook polls and consumes.
///
/// Failsafe: if CloudKit is disabled or no response arrives within the
/// per-request budget, no decision file is written — dc-hook falls back to
/// allow-and-exit-0 so agents never wedge.
@MainActor
final class ApprovalCoordinator {
    static let shared = ApprovalCoordinator()

    private let logger = Logger(subsystem: "com.doomcoder", category: "approval")
    private let container: CKContainer
    private let db: CKDatabase
    private let pollInterval: TimeInterval = 3.0
    private let totalBudget: TimeInterval = 25.0
    private var inflight: Set<String> = []

    private init() {
        container = CKContainer(identifier: CloudKitSchema.containerIdentifier)
        db = container.privateCloudDatabase
    }

    /// Entry point called from `AgentTrackingManager.ingest`. Cheap no-op if
    /// the envelope isn't waitable or the feature is off.
    func handleIfNeeded(envelope env: HookEnvelope) {
        guard FeatureFlags.cloudKitEnabled else { return }
        guard env.wantsBlockingReply, let requestId = env.requestId else { return }
        guard !inflight.contains(requestId) else { return }
        inflight.insert(requestId)
        Task { await runApprovalLoop(env: env, requestId: requestId) }
    }

    private func runApprovalLoop(env: HookEnvelope, requestId: String) async {
        defer { Task { @MainActor in self.inflight.remove(requestId) } }
        let toolName = (env.payloadDict?["tool_name"] as? String)
            ?? (env.payloadDict?["tool"] as? String)
            ?? env.event
        let toolArgs = (env.payloadDict?["tool_input"] as? [String: Any])
            ?? (env.payloadDict?["arguments"] as? [String: Any])
            ?? [:]
        let argsJSON = (try? JSONSerialization.data(withJSONObject: toolArgs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let now = Date()
        let req = CKApprovalRequest(
            requestId: requestId,
            sessionKey: deriveSessionKey(env: env),
            agent: env.agent,
            toolName: toolName,
            toolArgsJSON: argsJSON,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(7 * 86_400)
        )

        if !(await publishRequest(req)) {
            logger.error("approval publish failed for \(requestId, privacy: .public)")
            return
        }

        let deadline = Date().addingTimeInterval(totalBudget)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if let resp = await fetchResponse(requestId: requestId) {
                writeDecisionFile(requestId: requestId, decision: resp.decision.rawValue)
                logger.info("approval \(requestId, privacy: .public) → \(resp.decision.rawValue, privacy: .public)")
                return
            }
        }
        logger.notice("approval \(requestId, privacy: .public) timed out — failsafe allow")
    }

    private func publishRequest(_ req: CKApprovalRequest) async -> Bool {
        let rec = CKRecord(recordType: CloudKitSchema.RecordType.approvalRequest,
                           recordID: CKRecord.ID(recordName: req.recordName))
        rec["requestId"] = req.requestId as CKRecordValue
        rec["sessionKey"] = req.sessionKey as CKRecordValue
        rec["agent"] = req.agent as CKRecordValue
        rec["toolName"] = req.toolName as CKRecordValue
        rec["toolArgsJSON"] = req.toolArgsJSON as CKRecordValue
        rec["requestedAt"] = req.requestedAt as CKRecordValue
        rec["expiresAt"] = req.expiresAt as CKRecordValue

        return await withCheckedContinuation { cont in
            let op = CKModifyRecordsOperation(recordsToSave: [rec], recordIDsToDelete: nil)
            op.savePolicy = .changedKeys
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success: cont.resume(returning: true)
                case .failure: cont.resume(returning: false)
                }
            }
            db.add(op)
        }
    }

    private func fetchResponse(requestId: String) async -> CKApprovalResponse? {
        let rid = CKRecord.ID(recordName: requestId)
        return await withCheckedContinuation { cont in
            db.fetch(withRecordID: rid) { rec, err in
                guard err == nil, let rec else { cont.resume(returning: nil); return }
                guard rec.recordType == CloudKitSchema.RecordType.approvalResponse,
                      let decRaw = rec["decision"] as? String,
                      let dec = CKApprovalResponse.Decision(rawValue: decRaw),
                      let decidedAt = rec["decidedAt"] as? Date,
                      let device = rec["decidedByDevice"] as? String else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: CKApprovalResponse(
                    requestId: requestId, decision: dec,
                    decidedAt: decidedAt, decidedByDevice: device
                ))
            }
        }
    }

    private func writeDecisionFile(requestId: String, decision: String) {
        let dir = AgentSupportDir.url.appendingPathComponent("approvals", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(requestId).json")
        let payload: [String: Any] = ["decision": decision, "ts": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: url)
        }
    }

    private func deriveSessionKey(env: HookEnvelope) -> String {
        let host = env.macHostname ?? ProcessInfo.processInfo.hostName
        let suffix = env.cwdHashSuffix ?? CloudKitHash.fnv1a6(env.cwd)
        return "\(host)::\(env.agent)::\(suffix)"
    }
}
