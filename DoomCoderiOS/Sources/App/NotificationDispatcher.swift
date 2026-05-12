import Foundation
import CloudKit
import UserNotifications

@MainActor
final class NotificationDispatcher {
    static let shared = NotificationDispatcher()
    private init() {}

    func deliverApproval(recordName: String, record: CKRecord) async {
        let agent = (record["agent"] as? String) ?? "Agent"
        let tool = (record["toolName"] as? String) ?? "tool"
        let argsJSON = (record["toolArgsJSON"] as? String) ?? ""
        let preview = String(argsJSON.prefix(200))

        let content = UNMutableNotificationContent()
        content.title = "\(agent.capitalized) wants to run \(tool)"
        content.body = preview.isEmpty ? "Tap to review" : preview
        content.sound = .default
        content.threadIdentifier = "\(agent)::approval"
        content.categoryIdentifier = "APPROVAL_REQUEST"
        content.userInfo = ["requestId": recordName, "agent": agent, "toolName": tool]

        let approve = UNNotificationAction(identifier: "APPROVE", title: "Approve", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive, .authenticationRequired])
        let always = UNNotificationAction(identifier: "ALWAYS", title: "Always Allow This Tool", options: [.authenticationRequired])
        let category = UNNotificationCategory(identifier: "APPROVAL_REQUEST",
                                              actions: [approve, deny, always],
                                              intentIdentifiers: [],
                                              options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([category])

        let req = UNNotificationRequest(identifier: "approval.\(recordName)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    func deliverFailure(agent: String, cwd: String, tool: String, exitCode: Int, durationMs: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "\(agent.capitalized) failed in \(cwd)"
        content.body = "\(tool) exited with code \(exitCode) after \(durationMs/1000)s"
        content.sound = .default
        content.threadIdentifier = "\(agent)::\(cwd)"
        let req = UNNotificationRequest(identifier: "fail.\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    func deliverSummary(agent: String, cwd: String, toolCalls: Int, filesEdited: Int, durationSec: Int) async {
        let mins = durationSec / 60
        let secs = durationSec % 60
        let content = UNMutableNotificationContent()
        content.title = "\(agent.capitalized) finished \(cwd)"
        content.body = "\(toolCalls) tools · \(filesEdited) files edited · \(mins)m \(secs)s"
        content.sound = .default
        content.threadIdentifier = "\(agent)::\(cwd)"
        let req = UNNotificationRequest(identifier: "summary.\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }
}
