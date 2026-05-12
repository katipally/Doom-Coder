import AppIntents
import ActivityKit
import Foundation

@available(iOS 17.0, *)
struct ApproveIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Approve"
    @Parameter(title: "Request ID") var requestId: String
    @Parameter(title: "Agent") var agent: String
    @Parameter(title: "Tool") var tool: String

    init() {}
    init(requestId: String, agent: String, tool: String) {
        self.requestId = requestId; self.agent = agent; self.tool = tool
    }

    func perform() async throws -> some IntentResult {
        await ApprovalResponder.shared.respond(requestId: requestId, agent: agent, tool: tool, decision: "approve")
        return .result()
    }
}

@available(iOS 17.0, *)
struct DenyIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Deny"
    @Parameter(title: "Request ID") var requestId: String
    @Parameter(title: "Agent") var agent: String
    @Parameter(title: "Tool") var tool: String

    init() {}
    init(requestId: String, agent: String, tool: String) {
        self.requestId = requestId; self.agent = agent; self.tool = tool
    }

    func perform() async throws -> some IntentResult {
        await ApprovalResponder.shared.respond(requestId: requestId, agent: agent, tool: tool, decision: "deny")
        return .result()
    }
}

@available(iOS 17.0, *)
struct AlwaysAllowIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Always Allow"
    @Parameter(title: "Request ID") var requestId: String
    @Parameter(title: "Agent") var agent: String
    @Parameter(title: "Tool") var tool: String

    init() {}
    init(requestId: String, agent: String, tool: String) {
        self.requestId = requestId; self.agent = agent; self.tool = tool
    }

    func perform() async throws -> some IntentResult {
        await ApprovalResponder.shared.respond(requestId: requestId, agent: agent, tool: tool, decision: "always")
        return .result()
    }
}
