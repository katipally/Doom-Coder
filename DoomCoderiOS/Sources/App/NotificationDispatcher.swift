import Foundation
import CloudKit
import UserNotifications

@MainActor
final class NotificationDispatcher {
    static let shared = NotificationDispatcher()
    private init() {}

    private let appGroupId = "group.com.doomcoder.ios"

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
        let rawAgent  = (record["agent"] as? String) ?? "agent"
        let sessionKey = (record["sessionKey"] as? String) ?? recordName
        let tool      = (record["toolName"] as? String) ?? "tool"
        let argsJSON  = (record["toolArgsJSON"] as? String) ?? ""
        let body      = humanReadableArgs(argsJSON, tool: tool)

        let content = UNMutableNotificationContent()
        content.title = "\(agentDisplayName(rawAgent)) wants to \(tool)"
        content.body  = body
        content.sound = .default
        content.relevanceScore = 1.0
        content.threadIdentifier = sessionKey
        content.categoryIdentifier = "APPROVAL_REQUEST"
        content.userInfo = ["requestId": recordName, "agent": rawAgent,
                            "toolName": tool, "sessionKey": sessionKey]
        if let attachment = agentIconAttachment(for: rawAgent) {
            content.attachments = [attachment]
        }
        let req = UNNotificationRequest(identifier: "approval.\(recordName)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    func deliverApprovalFromAggregate(_ agg: CKSessionAggregate) async {
        guard let rid = agg.pendingRequestId else { return }
        let tool = agg.currentTool ?? "a tool"

        let content = UNMutableNotificationContent()
        content.title = "\(agentDisplayName(agg.agent)) is waiting for approval"
        content.body  = "\(tool) in \(agg.cwdBasename) needs your go-ahead"
        content.sound = .default
        content.relevanceScore = 1.0
        content.threadIdentifier = agg.sessionKey
        content.categoryIdentifier = "APPROVAL_REQUEST"
        content.userInfo = ["requestId": rid, "agent": agg.agent,
                            "toolName": tool, "sessionKey": agg.sessionKey]
        if let attachment = agentIconAttachment(for: agg.agent) {
            content.attachments = [attachment]
        }
        let req = UNNotificationRequest(identifier: "approval.\(agg.sessionKey)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    func deliverFailure(agent: String, sessionKey: String, cwd: String, tool: String,
                        exitCode: Int, durationMs: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "\(agentDisplayName(agent)) failed in \(cwd)"
        content.body  = "\(tool) exited \(exitCode) after \(durationMs / 1000)s"
        content.sound = .default
        content.relevanceScore = 0.8
        content.threadIdentifier = sessionKey
        if let attachment = agentIconAttachment(for: agent) {
            content.attachments = [attachment]
        }
        let req = UNNotificationRequest(identifier: "fail.\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    func deliverSummary(agent: String, sessionKey: String, cwd: String,
                        toolCalls: Int, filesEdited: Int, durationSec: Int) async {
        let mins = durationSec / 60; let secs = durationSec % 60
        let content = UNMutableNotificationContent()
        content.title = "\(agentDisplayName(agent)) finished · \(cwd)"
        content.body  = "\(toolCalls) tools · \(filesEdited) files · \(mins)m \(secs)s"
        content.sound = nil
        content.relevanceScore = 0.3
        content.threadIdentifier = sessionKey
        if let attachment = agentIconAttachment(for: agent) {
            content.attachments = [attachment]
        }
        let req = UNNotificationRequest(identifier: "summary.\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    /// Mirror of a macOS NotificationRouter push — shown when app is in foreground.
    func deliverGeneric(title: String, body: String, sessionKey: String? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        content.interruptionLevel = .active
        content.relevanceScore = 0.6
        if let sk = sessionKey { content.threadIdentifier = sk }
        let req = UNNotificationRequest(identifier: "generic.\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Helpers

    private func agentDisplayName(_ agent: String) -> String {
        AgentBrand(rawAgent: agent).fullDisplayName
    }

    /// Loads the bundled agent icon PNG from the shared App Group container.
    /// The main app writes these files to the container on first launch.
    private func agentIconAttachment(for rawAgent: String) -> UNNotificationAttachment? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return nil }
        let iconURL = container.appendingPathComponent("icon-\(rawAgent).png")
        guard FileManager.default.fileExists(atPath: iconURL.path) else { return nil }
        return try? UNNotificationAttachment(identifier: "agent-icon", url: iconURL, options: nil)
    }

    private func humanReadableArgs(_ json: String, tool: String) -> String {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Tap to review in app"
        }
        for key in ["cmd", "command", "file_path", "path", "query", "message", "input"] {
            if let val = dict[key] as? String, !val.isEmpty {
                return String(val.prefix(120))
            }
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
