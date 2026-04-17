import Foundation
import UserNotifications

// Fires macOS notifications for authoritative agent events (hook + MCP).
//
// As of v1.0 the heuristic fallback path (FSEvents / network-bytes / CPU
// sampling) is gone entirely. The only way a notification ever fires is via
// `fire(event:session:)` below, which is called by AgentStatusManager when it
// ingests a deterministic event from SocketServer.
@MainActor
final class NotificationManager {

    static let shared = NotificationManager()

    private var isAuthorized = false
    private var setupCalled  = false

    private init() {}

    // Call once after the app has fully launched (not during init). Currently
    // invoked lazily from `fire(event:session:)` on first attention event.
    func setup() {
        guard !setupCalled else { return }
        setupCalled = true
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
    func fire(event: AgentEvent, session: AgentSession) {
        if !setupCalled { setup() }
        guard event.status.isAttention else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(session.displayName) • \(event.status.displayName)"
        if let repo = session.repoName, !repo.isEmpty {
            content.subtitle = repo
        }
        content.body = event.message ?? defaultBody(for: event.status, session: session)
        content.sound = .default

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
