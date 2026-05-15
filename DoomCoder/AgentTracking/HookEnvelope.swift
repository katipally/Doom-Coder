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
        // v2.3.0+: only v=="2" envelopes are accepted. dc-hook binaries older
        // than v2 must be re-installed. Unknown versions are silently dropped.
        guard v == "2" else { return nil }
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
    let phase: NormalizedEventPhase
    let tool: String?
    let path: String?
    let timestamp: Date
    let summary: String
    let rawPayload: String?

    init(event: String, phase: NormalizedEventPhase = .other, tool: String? = nil,
         path: String? = nil, timestamp: Date = .now, summary: String = "",
         rawPayload: String? = nil) {
        self.id = UUID()
        self.event = event
        self.phase = phase
        self.tool = tool
        self.path = path
        self.timestamp = timestamp
        self.summary = summary
        self.rawPayload = rawPayload
    }
}

// MARK: - Notification policy

/// Determines whether an event should trigger a push notification.
/// Uses user-configurable NotificationPrefs stored in ChannelStore. Each
/// agent can have its own per-agent override; otherwise the global prefs
/// apply.
enum NotificationPolicy {
    /// Per-agent decision using both raw event name and phase. Checks per-event
    /// override first, falls back to phase-level bool.
    static func isNotifiable(agent: TrackedAgent, rawEvent: String, phase: NormalizedEventPhase) -> Bool {
        let prefs = ChannelStore.loadPrefs(for: agent)
        return prefs.shouldNotify(rawEvent: rawEvent, phase: phase.rawValue)
    }

    /// Phase-only check (no rawEvent) — kept for call sites that don't have a raw event.
    static func isNotifiable(agent: TrackedAgent, phase: NormalizedEventPhase) -> Bool {
        let prefs = ChannelStore.loadPrefs(for: agent)
        return prefs.shouldNotify(phase: phase.rawValue)
    }

    /// Legacy: check by raw agent + event name (for backward compat).
    static func isNotifiable(agent: TrackedAgent, event: String) -> Bool {
        let envelope = HookEnvelope(
            v: "2", agent: agent.rawValue, event: event,
            cwd: "", pid: 0, ts: Date().timeIntervalSince1970,
            synthetic: false, payloadRaw: nil
        )
        if let normalized = AgentTrackerRegistry.normalize(envelope: envelope) {
            return isNotifiable(agent: agent, phase: normalized.phase)
        }
        return false
    }

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
}
