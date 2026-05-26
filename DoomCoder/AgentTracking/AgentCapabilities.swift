// AgentCapabilities.swift — DoomCoder (Mac)
//
// Mirror of `Packages/DoomCoderCore/.../AgentCapabilities.swift`. The
// Mac app uses its own `TrackedAgent` (defined in `HookEnvelope.swift`)
// so this catalog can't live in the shared package — keeping the two
// in sync is a manual exercise (small surface, infrequent changes).
//
// Surfaces in the Configure → Agents detail pane so the user can see
// which notification categories each agent actually emits before
// committing to install hooks for it.

import Foundation
import SwiftUI

struct AgentCapability: Identifiable, Equatable {
    let id: String
    let title: String
    let symbolName: String
    let detail: String
}

enum AgentCapabilityCatalog {

    static let completed = AgentCapability(
        id: "completed",
        title: "Task completed",
        symbolName: "checkmark.circle.fill",
        detail: "Notifies when an agent run finishes successfully."
    )

    static let failed = AgentCapability(
        id: "failed",
        title: "Task failed",
        symbolName: "exclamationmark.triangle.fill",
        detail: "Notifies when an agent run errors out or is aborted."
    )

    static let waitingApproval = AgentCapability(
        id: "waiting_approval",
        title: "Waiting for approval",
        symbolName: "hand.raised.fill",
        detail: "Notifies when the agent asks you to approve a tool call (e.g. Claude elicitations)."
    )

    static let waitingInput = AgentCapability(
        id: "waiting_input",
        title: "Waiting for input",
        symbolName: "text.bubble.fill",
        detail: "Notifies when the agent is idle waiting for a chat reply."
    )

    static let sessionStart = AgentCapability(
        id: "session_start",
        title: "Session started",
        symbolName: "play.circle.fill",
        detail: "Lightweight log entry whenever a new agent session begins."
    )

    static let toolCalls = AgentCapability(
        id: "tool_calls",
        title: "Tool calls",
        symbolName: "wrench.and.screwdriver.fill",
        detail: "Tracks tool invocations (read/write/run) for session insight."
    )

    static func capabilities(for agent: TrackedAgent) -> [AgentCapability] {
        switch agent {
        case .claude:     return [completed, failed, waitingApproval, sessionStart, toolCalls]
        case .cursor:     return [completed, failed, sessionStart]
        case .vscode:     return [completed, failed, waitingInput, sessionStart]
        case .copilotCLI: return [completed, failed, waitingApproval, sessionStart, toolCalls]
        case .windsurf:   return [completed, failed, waitingInput, sessionStart]
        case .codexCLI:   return [completed, failed, sessionStart, toolCalls]
        }
    }
}
