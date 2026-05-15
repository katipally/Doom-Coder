import FoundationModels
import Foundation
import OSLog

// On-device Foundation Models judge for agents with limited hook coverage.
//
// Agents with full hooks (Claude, Cursor) handle notifications via direct
// hook-phase mapping. Agents with limited hooks (Windsurf, CopilotCLI,
// Codex, VSCode) route selected events here so the model can detect:
//   • "waiting" — agent paused, awaiting user input or approval
//   • "done"    — agent finished its current task/prompt cycle
//   • "error"   — fatal error or unexpected termination
//
// Single-shot: each evaluation creates a fresh LanguageModelSession.
// Context budget: tries last 3 recent events first; reduces to 2 or 1
// if the prompt would exceed 3,200 tokens (~80% of 4K window).
//
// Requires macOS 26+ with Apple Intelligence enabled.

@available(macOS 26.0, *)
actor FoundationModelJudge {
    let agent: TrackedAgent

    // Rolling buffer of recent envelopes per session (key = sessionKey).
    // Capped at maxSessions entries to prevent unbounded growth.
    private var recentBySession: [String: [HookEnvelope]] = [:]
    private let maxRecent = 3
    private let maxSessions = 50

    private let logger: Logger

    init(agent: TrackedAgent) {
        self.agent = agent
        self.logger = Logger(subsystem: "com.doomcoder", category: "fmjudge.\(agent.rawValue)")
    }

    // MARK: - Public evaluate entry point

    /// Evaluate a hook event and optionally send a notification.
    /// Returns immediately — FM inference runs concurrently.
    func evaluate(envelope: HookEnvelope, sessionKey: String) {
        let recent = recentBySession[sessionKey] ?? []
        // Append and cap per-session buffer
        var updated = recent + [envelope]
        if updated.count > maxRecent { updated = Array(updated.suffix(maxRecent)) }
        recentBySession[sessionKey] = updated

        // Prune stale sessions if the dictionary grows too large.
        // Keep only the most recently updated maxSessions entries.
        if recentBySession.count > maxSessions {
            let excess = recentBySession.count - maxSessions
            let oldest = recentBySession.keys.prefix(excess)
            for key in oldest { recentBySession.removeValue(forKey: key) }
        }

        let prevRecent = Array(recent.suffix(maxRecent))
        Task(priority: .background) { [agent, sessionKey, prevRecent, envelope, logger] in
            do {
                try await FoundationModelJudge.run(
                    agent: agent,
                    sessionKey: sessionKey,
                    currentEvent: envelope,
                    recentEvents: prevRecent,
                    logger: logger
                )
            } catch {
                logger.warning("FM judge error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - FM Session (static so it can be called from Task without self capture)

    private static func run(
        agent: TrackedAgent,
        sessionKey: String,
        currentEvent: HookEnvelope,
        recentEvents: [HookEnvelope],
        logger: Logger
    ) async throws {
        guard SystemLanguageModel.default.isAvailable else {
            logger.debug("Apple Intelligence not available; skipping FM evaluation")
            return
        }

        let notifyTool = SendNotificationTool(
            sessionKey: sessionKey, agent: agent, rawEvent: currentEvent.event
        )
        let classifyTool = ClassifyEventTool()

        let session = LanguageModelSession(
            tools: [classifyTool, notifyTool],
            instructions: systemPrompt(for: agent)
        )

        // Build prompt with adaptive context
        let prompt = try await buildAdaptivePrompt(
            currentEvent: currentEvent,
            recentEvents: recentEvents
        )

        logger.info("[FMJudge] agent=\(agent.rawValue, privacy: .public) event=\(currentEvent.event, privacy: .public) → evaluating")
        _ = try await withTimeout(seconds: 8, logger: logger, agent: agent, event: currentEvent.event) {
            _ = try await session.respond(to: prompt)
        }
    }

    // MARK: - Timeout helper

    private static func withTimeout(
        seconds: Double, logger: Logger, agent: TrackedAgent, event: String,
        body: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try await body()
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return false
            }
            guard let finished = try await group.next() else { group.cancelAll(); return }
            group.cancelAll()
            if !finished {
                logger.warning("[FMJudge] agent=\(agent.rawValue, privacy: .public) event=\(event, privacy: .public) → timed out after \(Int(seconds))s")
            } else {
                logger.info("[FMJudge] agent=\(agent.rawValue, privacy: .public) event=\(event, privacy: .public) → done")
            }
        }
    }

    // MARK: - Adaptive prompt builder

    /// Tries 3 → 2 → 1 recent events to stay within 3,200 token budget.
    private static func buildAdaptivePrompt(
        currentEvent: HookEnvelope,
        recentEvents: [HookEnvelope]
    ) async throws -> String {
        let model = SystemLanguageModel.default
        let fullPayload = compressedPayload(currentEvent, truncateResponse: true)

        for count in stride(from: min(recentEvents.count, 3), through: 0, by: -1) {
            let recent = Array(recentEvents.suffix(count))
            let prompt = assemblePrompt(currentPayload: fullPayload, recentEvents: recent)
            let tokens: Int
            if #available(macOS 26.4, *) {
                tokens = (try? await model.tokenCount(for: prompt)) ?? 0
            } else {
                tokens = prompt.count / 4  // tokenCount unavailable; conservative char/4 estimate
            }
            if tokens <= 3200 || count == 0 {
                return prompt
            }
        }
        // Fallback: macOS pre-26.4 or unexpected path — use minimal prompt
        return assemblePrompt(currentPayload: fullPayload, recentEvents: [])
    }

    private static func assemblePrompt(currentPayload: String, recentEvents: [HookEnvelope]) -> String {
        var parts = [String]()

        if !recentEvents.isEmpty {
            parts.append("Recent events (oldest first, compressed):")
            for e in recentEvents {
                let d = e.payloadDict ?? [:]
                let tool = d["tool_name"] as? String ?? d["toolName"] as? String ?? ""
                let exitCode = d["exit_code"] as? Int
                let ok = exitCode == 0 || d["success"] as? Bool == true
                parts.append("  {event:\"\(e.event)\", tool:\"\(tool)\", ok:\(ok)}")
            }
            parts.append("")
        }

        parts.append("Current event (full payload):")
        parts.append(currentPayload)
        parts.append("\nClassify and call tools if warranted.")

        return parts.joined(separator: "\n")
    }

    private static func compressedPayload(_ envelope: HookEnvelope, truncateResponse: Bool) -> String {
        guard let raw = envelope.payloadRaw,
              var str = String(data: raw, encoding: .utf8) else {
            return "{\"event\":\"\(envelope.event)\",\"agent\":\"\(envelope.agent)\"}"
        }
        // Truncate tool_response value to 500 chars
        if truncateResponse,
           let keyRange = str.range(of: "\"tool_response\":\"") {
            let valueStart = keyRange.upperBound
            let remaining = str[valueStart...]
            if remaining.count > 500 {
                str = String(str[..<valueStart]) + String(remaining.prefix(500)) + "...[truncated]\""
                // Close the JSON object if we broke it
                if !str.hasSuffix("}") { str += "}" }
            }
        }
        return str
    }

    // MARK: - System prompt

    private static func systemPrompt(for agent: TrackedAgent) -> String {
        """
        You are a notification judge for DoomCoder, an AI coding agent tracker app.
        You observe raw hook events from \(agent.displayName).

        Send notifications ONLY for exactly 3 situations:
        1. "waiting" — the agent is paused, expecting user input or approval
        2. "done"    — the agent finished its current task or prompt cycle
        3. "error"   — the agent encountered a fatal error or unexpected termination

        For all other events (mid-task tool calls, file reads, background activity), \
        call classify_event with type="none" and do NOT send a notification.

        Call send_notification only if you also classified as waiting/done/error.
        Write the notification body as one plain English sentence describing what happened.
        Be concise and accurate. Do not hallucinate details not present in the event data.
        """
    }
}

// MARK: - Tool: classify_event

@available(macOS 26.0, *)
struct ClassifyEventTool: Tool {
    typealias Output = String

    let name = "classify_event"
    let description = "Classify whether this hook event warrants a developer notification"

    @Generable
    struct Arguments {
        @Guide(description: "Event type: 'waiting', 'done', 'error', or 'none'")
        var type: String
        @Guide(description: "Confidence from 0.0 to 1.0")
        var confidence: Double
        @Guide(description: "One sentence explaining the classification")
        var reason: String
    }

    func call(arguments: Arguments) async throws -> String {
        return arguments.type
    }
}

// MARK: - Tool: send_notification

@available(macOS 26.0, *)
struct SendNotificationTool: Tool {
    typealias Output = String

    let name = "send_notification"
    let description = """
    Send a push notification to the developer.
    Call ONLY when the agent is: (1) waiting for user input, (2) done with its task, or (3) errored.
    """

    let sessionKey: String
    let agent: TrackedAgent
    let rawEvent: String

    @Generable
    struct Arguments {
        @Guide(description: "Short title, e.g. 'CopilotCLI · done' or 'Windsurf · needs you'")
        var title: String
        @Guide(description: "One plain-English sentence describing what happened")
        var body: String
        @Guide(description: "Urgency level: 'low', 'medium', or 'high'")
        var urgency: String
    }

    func call(arguments: Arguments) async throws -> String {
        // call() runs @concurrent; hop to main actor for NotificationDispatcher access.
        let key = sessionKey
        let ag = agent
        let ev = rawEvent
        let t = arguments.title
        let b = arguments.body
        let u = arguments.urgency
        await MainActor.run {
            NotificationDispatcher.shared.dispatchFMJudge(
                title: t, body: b, urgency: u,
                sessionKey: key, agent: ag, event: ev
            )
        }
        return "sent"
    }
}
