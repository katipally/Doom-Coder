import Foundation
import UserNotifications

// Fires macOS notifications for authoritative agent events (hook + MCP).
//
// As of v1.0 the heuristic fallback path (FSEvents / network-bytes / CPU
// sampling) is gone entirely. The only way a notification ever fires is via
// `fire(event:session:)` below, which is called by AgentStatusManager when it
// ingests a deterministic event from SocketServer.
@MainActor
final class NotificationManager: NSObject {

    static let shared = NotificationManager()

    private var isAuthorized = false
    private var setupCalled  = false

    // v1.8.1: interactive inactivity banner. The "End session" action lets
    // the user stop watching a session that's been idle for 2h+ without
    // having to bring DoomCoder to the front.
    private static let inactivityCategoryID = "doomcoder.inactivity"
    private static let endSessionActionID   = "END_SESSION"

    // Set by DoomCoderApp after AgentStatusManager is wired up so the
    // notification delegate can route the "End session" action.
    var onEndSession: ((String) -> Void)?

    private override init() { super.init() }

    // Call once after the app has fully launched (not during init). Currently
    // invoked lazily from `fire(event:session:)` on first attention event.
    func setup() {
        guard !setupCalled else { return }
        setupCalled = true

        let end = UNNotificationAction(
            identifier: Self.endSessionActionID,
            title: "End session",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.inactivityCategoryID,
            actions: [end],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().delegate = self

        Task {
            do {
                isAuthorized = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            } catch {
                isAuthorized = false
            }
        }
    }

    // MARK: - Agent-event path (Tier 1 / Tier 2)
    //
    // Called from AgentStatusManager whenever a hook or MCP event updates a
    // session. These events are deterministic — the agent itself told us what
    // happened — so we fire a banner immediately for attention events
    // (wait/error/done) and stay quiet for start/info events.
    //
    // v1.8.1: `.info` events are still silent unless the message is an
    // inactivity ping from the reaper, in which case we fire an interactive
    // banner with an "End session" action.
    func fire(event: AgentEvent, session: AgentSession) {
        if !setupCalled { setup() }

        let isInactivityPing = event.status == .info
            && (event.message ?? "").hasPrefix("Session inactive")

        guard event.status.isAttention || isInactivityPing else { return }

        let content = UNMutableNotificationContent()

        if isInactivityPing {
            content.title = "\(session.displayName) • Still tracking"
            if let repo = session.repoName, !repo.isEmpty { content.subtitle = repo }
            content.body  = event.message ?? "This session has been idle for a while."
            content.sound = nil
            content.categoryIdentifier = Self.inactivityCategoryID
            content.userInfo = ["sessionId": session.id]
        } else {
            content.title = "\(session.displayName) • \(event.status.displayName)"
            if let repo = session.repoName, !repo.isEmpty { content.subtitle = repo }
            // v1.7: canonical body, ignore agent-supplied message. Keeps mac
            // banners in lock-step with the iPhone ntfy pushes.
            content.body = event.status.canonicalBody
            content.sound = .default
        }

        let id = "doomcoder.agent.\(session.id).\(event.status.rawValue).\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)

        // Always try to deliver even if we haven't confirmed authorization yet.
        // UNUserNotificationCenter drops silently if permission was denied.
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func defaultBody(for status: AgentEvent.Status, session: AgentSession) -> String {
        switch status {
        case .wait:  return "Your agent is waiting for input."
        case .error: return "Your agent hit an error and paused."
        case .done:  return "Session finished after \(session.elapsedText)."
        case .start, .info: return ""
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo["sessionId"] as? String
        Task { @MainActor in
            if actionId == Self.endSessionActionID, let sid = sessionId {
                self.onEndSession?(sid)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Always show banners — we already filter attention events upstream.
        completionHandler([.banner, .sound])
    }
}
