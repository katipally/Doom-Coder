import Foundation

// Per-agent tracker silo. Each agent ships in its own file with full
// ownership of its event taxonomy, payload schema, and special-case
// logic. Previously, normalization lived in a single `AgentEventNormalizer.swift`
// with a shared protocol + registry — that conflated agents and silently
// dropped events when normalization failed. v2.3.0 splits this into one
// file per agent so each silo is independently auditable and editable.
//
// Architecture:
//   HookSocketListener ─► AgentTrackingManager.ingest(env)
//                              │
//                              ▼ (lookup by env.agent)
//                       AgentTrackerRegistry
//                              │
//                              ▼ (per-agent tracker)
//                       ClaudeTracker / CursorTracker / ...
//                              │
//                              ▼
//                       NormalizedHookEvent
//
// No tracker may drop a well-formed envelope — unknown events still flow
// through as `.other` so they appear in the Live Events / Logs pane.

// MARK: - Notification phase taxonomy
//
// This is the alerting taxonomy, NOT a cross-agent normalization. Every
// tracker decides for itself which of its native events maps to which
// phase. The phase only determines whether a notification fires (via the
// per-agent NotificationPrefs grid) and which copy template is used.

enum NormalizedEventPhase: String, Codable, Sendable, CaseIterable {
    case sessionStart
    case sessionEnd
    case userPrompt
    case toolStart
    case toolEnd
    case toolError
    case permissionNeeded
    case agentResponse
    case subagentStart
    case subagentEnd
    case error
    case fileChanged
    case other
}

/// The output of a per-agent tracker for a single raw hook envelope.
/// All fields preserved from the agent's native payload — no information
/// is discarded.
struct NormalizedHookEvent: Sendable {
    let agent: TrackedAgent
    let phase: NormalizedEventPhase
    let rawEvent: String
    let sessionId: String
    let toolName: String?
    let filePath: String?
    let cwd: String
    let timestamp: Date
    let summary: String
    let isFatal: Bool
    let payloadRaw: Data?
}

// MARK: - Tracker protocol

/// Per-agent tracker. Each tracker is a pure function from
/// `HookEnvelope` → `NormalizedHookEvent` and never has shared state.
/// Implementations live in `<Agent>Tracker.swift`.
protocol AgentTracker: Sendable {
    var agent: TrackedAgent { get }
    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent
}

// MARK: - Registry (thin router)

enum AgentTrackerRegistry {
    private static let trackers: [TrackedAgent: any AgentTracker] = [
        .claude:     ClaudeTracker(),
        .cursor:     CursorTracker(),
        .vscode:     VSCodeTracker(),
        .copilotCLI: CopilotCLITracker(),
        .windsurf:   WindsurfTracker(),
        .codexCLI:   CodexCLITracker(),
    ]

    /// Routes the envelope to the matching agent's tracker. Returns nil
    /// only when the agent tag is unknown — well-formed envelopes from
    /// known agents always produce a NormalizedHookEvent.
    static func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        guard let agent = TrackedAgent(rawValue: envelope.agent) else { return nil }
        return trackers[agent]?.normalize(envelope: envelope)
    }

    static func tracker(for agent: TrackedAgent) -> any AgentTracker {
        trackers[agent]!
    }
}

// MARK: - Agent run state
//
// Combines installed-state (config/binary present) with process-state
// (agent currently running) so the UI can show an accurate dot per
// agent without false positives. `active` adds a recency check on the
// last hook event (within 60 s) — used for the pulsing indicator.

enum AgentRunState: String, Sendable, Equatable {
    case notInstalled
    case installed
    case running
    case active
}

// MARK: - Agent state (5-state model)
// Replaces AgentRunState for the main tracking UI. AgentRunState is kept
// for AgentDetection/AgentDetector backward compatibility.

enum AgentState: String, Sendable, Equatable, CaseIterable {
    case notInstalled  // binary/app not found on this system
    case installed     // found but process not running
    case idle          // process running, at a prompt / waiting for user
    case working       // process running, actively executing tools or thinking
    case closed        // process was running but has now exited (clean or crash)

    var humanReadable: String {
        switch self {
        case .notInstalled: return "not installed"
        case .installed:    return "installed"
        case .idle:         return "idle"
        case .working:      return "working"
        case .closed:       return "closed"
        }
    }

    var isRunning: Bool { self == .idle || self == .working }
}

// MARK: - Shared helpers
//
// These are intentionally non-public to the rest of the app but shared
// across trackers in this file so each silo can use them without
// re-implementing trivial payload extraction.

func extractFilePath(from payload: [String: Any]) -> String? {
    if let p = payload["file_path"] as? String { return p }
    if let input = payload["input"] as? [String: Any],
       let p = input["file_path"] as? String { return p }
    return nil
}

func buildSummary(event: String, tool: String?, payload: [String: Any]) -> String {
    if let tool {
        if let filePath = extractFilePath(from: payload) {
            return "\(tool): \(URL(fileURLWithPath: filePath).lastPathComponent)"
        }
        return tool
    }
    return event
}
