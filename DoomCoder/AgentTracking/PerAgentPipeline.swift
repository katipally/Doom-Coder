import Foundation
import OSLog

// Background actor per tracked agent.
//
// Each agent gets its own Swift actor, which means normalization and SQLite
// persistence for different agents run concurrently on independent queues.
// A slow CopilotCLI hook burst can no longer stall Claude Code event
// processing (and vice-versa).
//
// Responsibilities:
//   1. Normalize raw HookEnvelope → NormalizedHookEvent (via the stateless tracker)
//   2. Persist to SQLite via EventStore (nonisolated, own serial queue)
//   3. Route events to FoundationModelJudge for agents with limited hook coverage
//      (Windsurf, CopilotCLI, Codex, VSCode) — macOS 26+ only

actor PerAgentPipeline {
    let agent: TrackedAgent
    private let tracker: any AgentTracker
    private let logger: Logger
    // Captured at init time (init runs on @MainActor, so shared access is safe).
    // EventStore.insert() is nonisolated — safe to call from this actor.
    private let eventStore: EventStore

    // FM judge for agents with insufficient hook coverage to detect
    // waiting/done/error directly. nil for Claude and Cursor (full hooks).
    private let fmJudge: (any Sendable)?  // actually FoundationModelJudge, erased for availability

    @MainActor
    init(agent: TrackedAgent) {
        self.agent = agent
        self.tracker = AgentTrackerRegistry.tracker(for: agent)
        self.logger = Logger(subsystem: "com.doomcoder", category: "pipeline.\(agent.rawValue)")
        self.eventStore = EventStore.shared

        if #available(macOS 26.0, *) {
            switch agent {
            case .windsurf, .copilotCLI, .codexCLI, .vscode:
                self.fmJudge = FoundationModelJudge(agent: agent)
            case .claude, .cursor:
                self.fmJudge = nil
            }
        } else {
            self.fmJudge = nil
        }
    }

    /// Normalize the envelope, persist to SQLite, and optionally route to FM judge.
    /// Always returns a NormalizedHookEvent for known agents.
    func process(_ envelope: HookEnvelope) -> NormalizedHookEvent {
        let normalized = tracker.normalize(envelope: envelope)
        let sessionKey = "\(normalized.agent.rawValue)::\(normalized.sessionId)"

        let payloadString = envelope.payloadRaw.flatMap { String(data: $0, encoding: .utf8) }
        eventStore.insert(
            sessionKey: sessionKey,
            agent: normalized.agent.rawValue,
            event: normalized.rawEvent,
            tool: normalized.toolName,
            path: normalized.cwd,
            state: normalized.phase.rawValue,
            ts: envelope.ts,
            payload: payloadString
        )

        logger.debug("processed event=\(normalized.rawEvent, privacy: .public) session=\(sessionKey, privacy: .public) phase=\(normalized.phase.rawValue, privacy: .public)")

        // Route to FM judge for phases that can't be detected via direct hooks.
        // Skips sessionStart so the model only sees substantive activity.
        if #available(macOS 26.0, *),
           let judge = fmJudge as? FoundationModelJudge,
           shouldRunFMJudge(for: normalized.phase) {
            Task { await judge.evaluate(envelope: envelope, sessionKey: sessionKey) }
        }

        return normalized
    }

    // Only submit events where hook data is substantive enough for the FM to reason about.
    // sessionStart is excluded — not enough context yet.
    // permissionNeeded and agentResponse are excluded — already handled by direct dispatch.
    private func shouldRunFMJudge(for phase: NormalizedEventPhase) -> Bool {
        switch phase {
        case .toolEnd, .toolError, .sessionEnd, .error, .other:
            return true
        case .sessionStart, .userPrompt, .toolStart,
             .permissionNeeded, .agentResponse,
             .subagentStart, .subagentEnd, .fileChanged:
            return false
        }
    }
}
