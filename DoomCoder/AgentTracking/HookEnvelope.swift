import Foundation

// The JSON envelope written by dc-hook to the unix socket.
// Keep in lock-step with dc-hook/main.swift.
struct HookEnvelope: Sendable {
    let v: String
    let agent: String
    let event: String
    let cwd: String
    let pid: Int
    let ts: TimeInterval
    let synthetic: Bool
    let payloadRaw: Data?

    var payloadDict: [String: Any]? {
        guard let d = payloadRaw else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func decode(_ data: Data) -> HookEnvelope? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let v = obj["v"] as? String,
              let agent = obj["agent"] as? String,
              let event = obj["event"] as? String else { return nil }
        let cwd = (obj["cwd"] as? String) ?? ""
        let pid = (obj["pid"] as? Int) ?? 0
        let ts = (obj["ts"] as? TimeInterval) ?? Date().timeIntervalSince1970
        let synthetic = (obj["synthetic"] as? Bool) ?? false
        var payloadRaw: Data? = nil
        if let p = obj["payload"] {
            payloadRaw = try? JSONSerialization.data(withJSONObject: p, options: [])
        }
        return HookEnvelope(v: v, agent: agent, event: event, cwd: cwd, pid: pid, ts: ts, synthetic: synthetic, payloadRaw: payloadRaw)
    }
}

// MARK: - Timeline event (raw event in a session's ordered log)

struct TimelineEvent: Identifiable, Sendable {
    let id: UUID
    let event: String
    let tool: String?
    let path: String?
    let timestamp: Date
    let summary: String

    init(event: String, tool: String? = nil, path: String? = nil, timestamp: Date = .now, summary: String = "") {
        self.id = UUID()
        self.event = event
        self.tool = tool
        self.path = path
        self.timestamp = timestamp
        self.summary = summary
    }
}

// MARK: - Notification policy

/// Per-agent milestone events that should trigger push notifications.
/// Everything else is stored in the session timeline but stays silent.
enum NotificationPolicy {
    /// Milestone events per agent that warrant a push notification.
    static func isNotifiable(agent: TrackedAgent, event: String) -> Bool {
        switch agent {
        case .claude:
            return claudeMilestones.contains(event)
        case .cursor:
            return cursorMilestones.contains(event)
        case .vscode:
            return vscodeMilestones.contains(event)
        case .copilotCLI:
            return copilotCLIMilestones.contains(event)
        }
    }

    private static let claudeMilestones: Set<String> = [
        "SessionStart", "SessionEnd", "Notification",
        "Stop", "StopFailure", "PermissionRequest",
        "TaskCompleted"
    ]

    private static let cursorMilestones: Set<String> = [
        "sessionStart", "sessionEnd",
        "afterAgentResponse", "stop"
    ]

    private static let vscodeMilestones: Set<String> = [
        "SessionStart", "SessionEnd",
        "Stop", "PermissionRequest"
    ]

    private static let copilotCLIMilestones: Set<String> = [
        "sessionStart", "sessionEnd", "errorOccurred"
    ]

    /// Whether the event signals that a session has ended.
    static func isTerminal(event: String) -> Bool {
        let e = event.lowercased()
        return e.contains("sessionend") || e.contains("stop") || e == "taskcompleted"
    }
}

// MARK: - Agent identity

enum TrackedAgent: String, CaseIterable, Sendable {
    case claude
    case cursor
    case vscode
    case copilotCLI = "copilot_cli"

    var displayName: String {
        switch self {
        case .claude:     return "Claude Code"
        case .cursor:     return "Cursor"
        case .vscode:     return "VS Code Copilot"
        case .copilotCLI: return "Copilot CLI"
        }
    }
}
