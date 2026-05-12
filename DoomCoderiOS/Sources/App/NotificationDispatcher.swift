import Foundation
import CloudKit
import UserNotifications

@MainActor
final class NotificationDispatcher {
    static let shared = NotificationDispatcher()
    private init() {}

    // Call once at app startup.
    nonisolated static func registerCategories() {
        let approve = UNNotificationAction(identifier: "APPROVE", title: "Approve",
                                           options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny",
                                        options: [.destructive, .authenticationRequired])
        let always = UNNotificationAction(identifier: "ALWAYS", title: "Always Allow This Tool",
                                          options: [.authenticationRequired])
        let category = UNNotificationCategory(identifier: "APPROVAL_REQUEST",
                                              actions: [approve, deny, always],
                                              intentIdentifiers: [],
                                              options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func deliverApproval(recordName: String, record: CKRecord) async {
        let rawAgent = (record["agent"] as? String) ?? "agent"
        let agent = agentDisplayName(rawAgent)
        let tool  = (record["toolName"] as? String) ?? "tool"
        let argsJSON = (record["toolArgsJSON"] as? String) ?? ""
        let body = humanReadableArgs(argsJSON, tool: tool)

        let content = UNMutableNotificationContent()
        content.title = "\(agent) wants to \(tool)"
        content.body = body
        content.sound = .default
        content.relevanceScore = 1.0
        content.threadIdentifier = "\(rawAgent)::approval"
        content.categoryIdentifier = "APPROVAL_REQUEST"
        content.userInfo = ["requestId": recordName, "agent": rawAgent, "toolName": tool]

        let req = UNNotificationRequest(identifier: "approval.\(recordName)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    /// Deliver an approval notification sourced from a `CKSessionAggregate`
    /// (macOS writes approval state into the aggregate, not a separate ApprovalRequest record).
    func deliverApprovalFromAggregate(_ agg: CKSessionAggregate) async {
        guard let rid = agg.pendingRequestId else { return }
        let displayName = agentDisplayName(agg.agent)
        let tool = agg.currentTool ?? "a tool"

        let content = UNMutableNotificationContent()
        content.title = "\(displayName) is waiting for approval"
        content.body = "\(tool) in \(agg.cwdBasename) needs your go-ahead"
        content.sound = .default
        content.relevanceScore = 1.0
        content.threadIdentifier = "\(agg.agent)::approval"
        content.categoryIdentifier = "APPROVAL_REQUEST"
        content.userInfo = [
            "requestId": rid,
            "agent": agg.agent,
            "toolName": tool,
            "sessionKey": agg.sessionKey
        ]

        let req = UNNotificationRequest(identifier: "approval.\(agg.sessionKey)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    func deliverFailure(agent: String, cwd: String, tool: String, exitCode: Int, durationMs: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "\(agentDisplayName(agent)) failed in \(cwd)"
        content.body = "\(tool) exited \(exitCode) after \(durationMs / 1000)s"
        content.sound = .default
        content.relevanceScore = 0.8
        content.threadIdentifier = "\(agent)::\(cwd)"
        let req = UNNotificationRequest(identifier: "fail.\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    func deliverSummary(agent: String, cwd: String, toolCalls: Int, filesEdited: Int, durationSec: Int) async {
        let mins = durationSec / 60; let secs = durationSec % 60
        let content = UNMutableNotificationContent()
        content.title = "\(agentDisplayName(agent)) finished · \(cwd)"
        content.body = "\(toolCalls) tools · \(filesEdited) files · \(mins)m \(secs)s"
        content.sound = .none
        content.relevanceScore = 0.3
        content.threadIdentifier = "\(agent)::\(cwd)"
        let req = UNNotificationRequest(identifier: "summary.\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Helpers

    private func agentDisplayName(_ agent: String) -> String {
        switch agent {
        case "claude":      return "Claude Code"
        case "cursor":      return "Cursor"
        case "vscode":      return "VS Code"
        case "copilot_cli": return "Copilot CLI"
        case "windsurf":    return "Windsurf"
        case "codex_cli":   return "Codex CLI"
        default:            return agent.capitalized
        }
    }

    private func humanReadableArgs(_ json: String, tool: String) -> String {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Tap to review in app"
        }
        // Keys in priority order that give human-readable content.
        for key in ["cmd", "command", "file_path", "path", "query", "message", "input"] {
            if let val = dict[key] as? String, !val.isEmpty {
                return String(val.prefix(120))
            }
            // Nested under "input" dict
            if key == "input", let inner = dict[key] as? [String: Any] {
                for innerKey in ["cmd", "command", "file_path", "path", "query"] {
                    if let val = inner[innerKey] as? String, !val.isEmpty {
                        return String(val.prefix(120))
                    }
                }
            }
        }
        return String(json.prefix(120))
    }
}
