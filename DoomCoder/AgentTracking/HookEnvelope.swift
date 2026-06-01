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
// Kept as a lightweight in-memory model for Connection Doctor / test replay.
struct TimelineEvent: Identifiable, Sendable {
    let id: UUID
    let event: String
    let tool: String?
    let path: String?
    let timestamp: Date

    init(event: String, tool: String? = nil, path: String? = nil, timestamp: Date = .now) {
        self.id = UUID()
        self.event = event
        self.tool = tool
        self.path = path
        self.timestamp = timestamp
    }
}

// Notification gating now lives in `AgentNotificationPrefs.shouldNotify`
// (per-agent), evaluated at dispatch time in `AgentTrackingManager.ingest`.

// MARK: - Notification names

extension Notification.Name {
    /// Posted by AgentTrackingManager.ingest() after each event is written to SQLite.
    static let doomcoderNewEvent = Notification.Name("com.doomcoder.newEvent")
    /// Posted by AgentProcessMonitor when any agent's running state changes.
    static let doomcoderProcessStateChanged = Notification.Name("com.doomcoder.processStateChanged")
}

enum TrackedAgent: String, CaseIterable, Sendable {
    case claude
    case cursor
    case vscode
    case copilotCLI = "copilot_cli"
    case windsurf
    case codexCLI = "codex_cli"

    var displayName: String {
        switch self {
        case .claude:     return "Claude Code"
        case .cursor:     return "Cursor"
        case .vscode:     return "VS Code Copilot"
        case .copilotCLI: return "Copilot CLI"
        case .windsurf:   return "Windsurf"
        case .codexCLI:   return "Codex CLI"
        }
    }

    /// True for IDE-based agents (open = idle); false for CLI agents (transient processes).
    var isIDEAgent: Bool {
        switch self {
        case .cursor, .vscode, .windsurf: return true
        case .claude, .copilotCLI, .codexCLI: return false
        }
    }

    /// How trustworthy this agent's permission hook is as a "the agent is truly
    /// blocked, waiting on you" signal.
    ///
    /// - `.reliable`: the hook fires ONLY when the agent is genuinely blocked
    ///   (Claude, VS Code Copilot, Codex). The alert fires immediately — no
    ///   added latency.
    /// - `.preDecision`: the hook fires BEFORE the agent's own allow-list /
    ///   auto-approve decision runs (Copilot CLI, Cursor, Windsurf), so it
    ///   spams permission events for actions that never actually block. These
    ///   go through `ApprovalArbiter`, which defers the alert briefly and
    ///   cancels it if the action turns out to have run on its own.
    var permissionHookReliability: PermissionHookReliability {
        switch self {
        case .claude, .vscode, .codexCLI: return .reliable
        case .copilotCLI, .cursor, .windsurf: return .preDecision
        }
    }
}

/// Reliability classification for an agent's permission hook. See
/// `TrackedAgent.permissionHookReliability`.
enum PermissionHookReliability: Sendable {
    case reliable
    case preDecision
}
