// NotificationService.swift
// Notification Service Extension — runs in its own OS process, even when the iOS app
// is fully terminated. Intercepts alert pushes with mutable-content=1 from CloudKit,
// reads the embedded record fields (desiredKeys), and builds a rich notification.
// This is the key piece that makes DoomCoder notifications work like ntfy.

import UserNotifications
import OSLog

private let nseLog = Logger(subsystem: "com.doomcoder.ios.notificationservice", category: "NSE")

final class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let content = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        // Register APPROVAL_REQUEST category so Approve/Deny action buttons work
        // even when the main app is not running.
        registerCategoriesIfNeeded()

        let userInfo = request.content.userInfo
        nseLog.info("NSE received push. Keys: \(userInfo.keys.map { "\($0)" }.joined(separator: ", "), privacy: .public)")

        // CloudKit embeds record fields at userInfo["ck"]["qry"]["fo"] as a dict.
        // Shape: {"ck": {"qry": {"rid": "<recordName>", "fo": {"status": "...", ...}}}}
        if let ck = userInfo["ck"] as? [String: Any],
           let qry = ck["qry"] as? [String: Any] {
            let recordName = qry["rid"] as? String ?? ""
            let fields = qry["fo"] as? [String: Any] ?? [:]
            nseLog.info("CK record \(recordName, privacy: .public), fields: \(fields.keys.joined(separator: ", "), privacy: .public)")
            enrichContent(content, recordName: recordName, fields: fields)
        } else {
            // Fallback: no embedded fields — show a generic useful notification.
            content.title = "DoomCoder"
            content.body = "Agent update — tap to view"
        }

        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        // iOS is killing us — deliver the best content we have so far.
        if let contentHandler, let content = bestAttemptContent {
            contentHandler(content)
        }
    }

    // MARK: - Enrich notification content from embedded record fields

    private func enrichContent(
        _ content: UNMutableNotificationContent,
        recordName: String,
        fields: [String: Any]
    ) {
        let status      = fields["status"]          as? String ?? ""
        let agent       = fields["agent"]           as? String ?? "Agent"
        let cwd         = fields["cwdBasename"]     as? String ?? ""
        let tool        = fields["currentTool"]     as? String ?? ""
        let sessionKey  = fields["sessionKey"]      as? String ?? recordName
        let requestId   = fields["pendingRequestId"] as? String
        let toolCalls   = fields["totalToolCalls"]  as? Int ?? 0
        let filesEdited = fields["totalFilesEdited"] as? Int ?? 0

        let agentName = displayName(for: agent)
        let cwdLabel  = cwd.isEmpty ? "" : " · \(cwd)"

        switch status {
        case "waitingApproval":
            content.title = "\(agentName) needs your approval"
            let toolLabel = tool.isEmpty ? "an action" : tool
            content.body = "\(toolLabel)\(cwdLabel)"
            content.categoryIdentifier = "APPROVAL_REQUEST"
            // Stash requestId so the Approve/Deny intent can read it.
            if let rid = requestId {
                var info = content.userInfo
                info["pendingRequestId"] = rid
                info["sessionKey"] = sessionKey
                info["agent"] = agent
                content.userInfo = info
            }
            content.interruptionLevel = .active

        case "failed":
            content.title = "\(agentName) failed"
            let toolLabel = tool.isEmpty ? "" : " while \(tool)"
            content.body = "Error\(toolLabel)\(cwdLabel)"
            content.interruptionLevel = .active

        case "completed":
            content.title = "\(agentName) finished"
            var parts: [String] = []
            if toolCalls > 0 { parts.append("\(toolCalls) tool\(toolCalls == 1 ? "" : "s")") }
            if filesEdited > 0 { parts.append("\(filesEdited) file\(filesEdited == 1 ? "" : "s")") }
            if !cwd.isEmpty { parts.append(cwd) }
            content.body = parts.isEmpty ? "Session complete" : parts.joined(separator: " · ")
            content.interruptionLevel = .passive

        case "running":
            // Drop running-state updates — they're not user-actionable.
            // Show a minimal update only if the tool name is interesting.
            if tool.isEmpty {
                content.title = "DoomCoder"
                content.body = "\(agentName) is working\(cwdLabel)"
            } else {
                content.title = "\(agentName) is working"
                content.body = "\(tool)\(cwdLabel)"
            }
            content.interruptionLevel = .passive

        default:
            content.title = "DoomCoder"
            content.body = "\(agentName) — \(status)\(cwdLabel)"
            content.interruptionLevel = .passive
        }

        content.threadIdentifier = sessionKey
        content.relevanceScore = relevanceScore(for: status)
        content.sound = status == "waitingApproval" || status == "failed" ? .default : nil
    }

    // MARK: - Helpers

    private func displayName(for rawAgent: String) -> String {
        switch rawAgent.lowercased() {
        case "claude":                  return "Claude"
        case "cursor":                  return "Cursor"
        case "vscode", "vs code":      return "VS Code"
        case "copilot_cli", "copilot": return "GitHub Copilot"
        case "windsurf":               return "Windsurf"
        case "codex_cli", "codex":     return "Codex CLI"
        default:                       return rawAgent.capitalized
        }
    }

    private func relevanceScore(for status: String) -> Double {
        switch status {
        case "waitingApproval": return 1.0
        case "failed":          return 0.8
        case "completed":       return 0.5
        default:                return 0.2
        }
    }

    private func registerCategoriesIfNeeded() {
        let approve = UNNotificationAction(
            identifier: "APPROVE_ACTION",
            title: "Approve",
            options: [.authenticationRequired])
        let deny = UNNotificationAction(
            identifier: "DENY_ACTION",
            title: "Deny",
            options: [.destructive, .authenticationRequired])
        let always = UNNotificationAction(
            identifier: "ALWAYS_ALLOW_ACTION",
            title: "Always Allow",
            options: [.authenticationRequired])
        let approvalCategory = UNNotificationCategory(
            identifier: "APPROVAL_REQUEST",
            actions: [approve, deny, always],
            intentIdentifiers: [],
            options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([approvalCategory])
    }
}
