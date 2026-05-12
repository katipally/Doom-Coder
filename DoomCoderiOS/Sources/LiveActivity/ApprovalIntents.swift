import AppIntents
import ActivityKit
import CloudKit
import Foundation
import UIKit

@available(iOS 17.0, *)
struct ApproveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Approve"
    @Parameter(title: "Request ID") var requestId: String
    @Parameter(title: "Agent") var agent: String
    @Parameter(title: "Tool") var tool: String

    init() {}
    init(requestId: String, agent: String, tool: String) {
        self.requestId = requestId; self.agent = agent; self.tool = tool
    }

    func perform() async throws -> some IntentResult {
        try? await ApprovalIntentHelper.write(requestId: requestId, decision: "approve")
        await MainActor.run { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        return .result()
    }
}

@available(iOS 17.0, *)
struct DenyIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny"
    @Parameter(title: "Request ID") var requestId: String
    @Parameter(title: "Agent") var agent: String
    @Parameter(title: "Tool") var tool: String

    init() {}
    init(requestId: String, agent: String, tool: String) {
        self.requestId = requestId; self.agent = agent; self.tool = tool
    }

    func perform() async throws -> some IntentResult {
        try? await ApprovalIntentHelper.write(requestId: requestId, decision: "deny")
        await MainActor.run { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        return .result()
    }
}

@available(iOS 17.0, *)
struct AlwaysAllowIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Always Allow"
    @Parameter(title: "Request ID") var requestId: String
    @Parameter(title: "Agent") var agent: String
    @Parameter(title: "Tool") var tool: String

    init() {}
    init(requestId: String, agent: String, tool: String) {
        self.requestId = requestId; self.agent = agent; self.tool = tool
    }

    func perform() async throws -> some IntentResult {
        // Write "always" to CloudKit — macOS side honours the always-allow decision.
        // UserDefaults.standard in the widget extension is isolated from the app sandbox,
        // so we skip local storage here; the app's ApprovalResponder.AlwaysAllowStore handles persistence.
        try? await ApprovalIntentHelper.write(requestId: requestId, decision: "always")
        await MainActor.run { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        return .result()
    }
}

private enum ApprovalIntentHelper {
    static func write(requestId: String, decision: String) async throws {
        let container = CKContainer(identifier: "iCloud.com.doomcoder.app")
        let db = container.privateCloudDatabase
        let rec = CKRecord(recordType: "ApprovalResponse", recordID: CKRecord.ID(recordName: requestId))
        rec["requestId"] = requestId as CKRecordValue
        rec["decision"] = decision as CKRecordValue
        rec["decidedAt"] = Date() as CKRecordValue
        let uuid = UserDefaults.standard.string(forKey: "device.uuid") ?? UUID().uuidString
        rec["decidedByDevice"] = uuid as CKRecordValue
        _ = try await db.save(rec)
    }
}

