import Foundation
import UserNotifications
import DoomCodeCore

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

    // MARK: - Public notification triggers

    /// Why the Mac is now being held awake. Drives the body copy so the user
    /// can tell at a glance whether it's the agent, their own activity, or a
    /// snooze override keeping the Mac awake.
    enum TakeReason: Sendable {
        /// One or more tracked agents is actively working.
        case agents([String])
        /// No agents working, but the user has been at the keyboard / mouse
        /// within the silence window. Mac stays awake while you're active.
        case userActive
        /// A snooze override is in effect. Mac stays awake regardless of
        /// agent or user activity until the timer ends.
        case snoozed

        /// Localized body copy. Kept short — the system notification can
        /// only comfortably fit ~80 characters.
        var body: String {
            switch self {
            case .agents(let names):
                if names.isEmpty { return "DoomCode is holding sleep for your agents." }
                if names.count == 1 { return "\(names[0]) is working." }
                return "\(names.prefix(2).joined(separator: " & ")) are working."
            case .userActive:
                return "You're active — DoomCode is holding sleep."
            case .snoozed:
                return "Snooze active — DoomCode is holding sleep."
            }
        }
    }

    func notifyTookControl(reason: TakeReason) {
        // v2.6: removed the 20s debounce. The acquire guard in
        // SleepManager.acquireAssertion() already prevents duplicate fires
        // within a single active session (acquire only runs on the
        // inactive→active transition). The debounce was previously
        // suppressing legitimate feedback when the user toggled modes
        // rapidly (e.g. Auto → Off → Auto) and they expected a notification
        // each time. The 10-min silence window in evaluateAuto is what
        // actually prevents oscillation.
        let title = "Keeping Mac Awake"
        post(title: title, body: reason.body, identifier: "sleep.took.\(UUID().uuidString)")
    }

    /// Backwards-compatible overload: derives the reason from the agent
    /// names. New code should pass an explicit `TakeReason`.
    func notifyTookControl(agentNames: [String]) {
        let reason: TakeReason = agentNames.isEmpty ? .userActive : .agents(agentNames)
        notifyTookControl(reason: reason)
    }

    func notifyReleasedControl() {
        post(title: "Sleep Control Returned",
             body: "All agents finished. Your Mac can sleep normally.",
             identifier: "sleep.released")
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
