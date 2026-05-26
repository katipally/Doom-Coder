// AgentCapabilities.swift — DoomCoderCore
//
// Per-agent declaration of which notification categories the agent's hook
// configuration is able to fire. Surfaced in the Mac Configure Agents
// detail pane and (read-only) in the iOS Companion's agent detail view so
// the user knows what to expect before enabling tracking.
//
// The matrix below is **descriptive** — it documents what the underlying
// hook surface area of each agent allows DoomCoder to detect, not what the
// user's settings are. Toggle-level filtering is independent.

import Foundation

public struct AgentCapability: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let symbolName: String
    /// One-sentence description for tooltip / detail row.
    public let detail: String

    public init(id: String, title: String, symbolName: String, detail: String) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.detail = detail
    }
}

public enum AgentCapabilityCatalog {

    public static let completed = AgentCapability(
        id: "completed",
        title: "Task completed",
        symbolName: "checkmark.circle.fill",
        detail: "Notifies when an agent run finishes successfully."
    )

    public static let failed = AgentCapability(
        id: "failed",
        title: "Task failed",
        symbolName: "exclamationmark.triangle.fill",
        detail: "Notifies when an agent run errors out or is aborted."
    )

    public static let waitingApproval = AgentCapability(
        id: "waiting_approval",
        title: "Waiting for approval",
        symbolName: "hand.raised.fill",
        detail: "Notifies when the agent asks you to approve a tool call (e.g. Claude elicitations)."
    )

    public static let waitingInput = AgentCapability(
        id: "waiting_input",
        title: "Waiting for input",
        symbolName: "text.bubble.fill",
        detail: "Notifies when the agent is idle waiting for a chat reply."
    )

    public static let sessionStart = AgentCapability(
        id: "session_start",
        title: "Session started",
        symbolName: "play.circle.fill",
        detail: "Lightweight log entry whenever a new agent session begins."
    )

    public static let toolCalls = AgentCapability(
        id: "tool_calls",
        title: "Tool calls",
        symbolName: "wrench.and.screwdriver.fill",
        detail: "Tracks tool invocations (read/write/run) for session insight."
    )

    /// Returns the capability list for the given agent, in display order.
    public static func capabilities(for agent: TrackedAgent) -> [AgentCapability] {
        switch agent {
        case .claude:
            return [completed, failed, waitingApproval, sessionStart, toolCalls]
        case .cursor:
            return [completed, failed, sessionStart]
        case .vscode:
            return [completed, failed, waitingInput, sessionStart]
        case .copilotCLI:
            return [completed, failed, waitingApproval, sessionStart, toolCalls]
        case .windsurf:
            return [completed, failed, waitingInput, sessionStart]
        case .codexCLI:
            return [completed, failed, sessionStart, toolCalls]
        }
    }

    /// Short one-line summary suitable for a settings row subtitle.
    public static func summary(for agent: TrackedAgent) -> String {
        let titles = capabilities(for: agent).prefix(3).map(\.title).joined(separator: " · ")
        return titles
    }
}
