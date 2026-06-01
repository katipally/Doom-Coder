import Foundation
import UserNotifications
import DoomCoderCore

/// Posts system-level sleep control notifications through both the local
/// macOS notification center and the CloudKit pipeline so iOS also receives
/// them as push notifications.
///
/// These are not agent-hook events, so they bypass NotificationDispatcher
/// and write NotificationLogRecord directly to CloudKitPusher.
@MainActor
final class SleepStateNotifier {
    static let shared = SleepStateNotifier()
    private init() {}

    /// Debounce: don't re-notify "took control" more than once per minute.
    private var _lastTookControlAt: Date = .distantPast

    // MARK: - Public notification triggers

    func notifyTookControl(agentNames: [String]) {
        guard Date().timeIntervalSince(_lastTookControlAt) > 60 else { return }
        _lastTookControlAt = Date()
        let title = "Keeping Mac Awake"
        let body: String
        if agentNames.isEmpty {
            body = "DoomCoder is holding sleep for your agents."
        } else if agentNames.count == 1 {
            body = "\(agentNames[0]) is working."
        } else {
            body = "\(agentNames.prefix(2).joined(separator: " & ")) are working."
        }
        post(title: title, body: body, identifier: "sleep.took")
    }

    func notifyReleasedControl() {
        post(title: "Sleep Control Returned",
             body: "All agents finished. Your Mac can sleep normally.",
             identifier: "sleep.released")
    }

    func notifyAgentStuck(agentName: String) {
        post(title: "\(agentName) Is Waiting",
             body: "\(agentName) has been waiting for approval for 30 minutes.",
             identifier: "sleep.stuck.\(agentName)")
    }

    func notifyStaleRelease() {
        post(title: "Mac Can Sleep Now",
             body: "Agents have been idle for 30 minutes. Sleep control returned.",
             identifier: "sleep.stale")
    }

    // MARK: - Internal dispatch

    private func post(title: String, body: String, identifier: String) {
        postLocal(title: title, body: body, identifier: identifier)
        postCloudKit(title: title, body: body, identifier: identifier)
    }

    private func postLocal(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: identifier,
                                        content: content,
                                        trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(req) }
    }

    private func postCloudKit(title: String, body: String, identifier: String) {
        let pusher = CloudKitPusher.shared
        let rec = NotificationLogRecord(
            sessionKey: "system",
            macId: pusher.macId,
            macName: pusher.macName,
            agent: "doomcoder",
            phase: identifier,
            rawEvent: identifier,
            title: title,
            body: body,
            channel: "iOS",
            success: true,
            ts: Date()
        )
        pusher.publishNotificationLog(rec)
    }
}
