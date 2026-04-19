import Foundation

// MARK: - Normalized event model

/// Unified event phase taxonomy across all AI agents. Raw agent events are
/// mapped to these phases by per-agent normalizers.
enum NormalizedEventPhase: String, Codable, Sendable {
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

/// Normalized event produced by per-agent normalizers. Contains all the
/// fields needed by SessionAggregate and notification dispatch.
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

// MARK: - Per-agent normalizer protocol

protocol AgentEventNormalizer: Sendable {
    var agent: TrackedAgent { get }
    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent?
}

// MARK: - Claude Code normalizer

struct ClaudeEventNormalizer: AgentEventNormalizer {
    let agent = TrackedAgent.claude

    private static let phaseMap: [String: NormalizedEventPhase] = [
        "SessionStart":       .sessionStart,
        "SessionEnd":         .sessionEnd,
        "UserPromptSubmit":   .userPrompt,
        "PreToolUse":         .toolStart,
        "PostToolUse":        .toolEnd,
        "PostToolUseFailure": .toolError,
        "PermissionRequest":  .permissionNeeded,
        "PermissionDenied":   .permissionNeeded,
        "Notification":       .agentResponse,
        "Stop":               .sessionEnd,
        "StopFailure":        .error,
        "SubagentStart":      .subagentStart,
        "SubagentStop":       .subagentEnd,
        "TaskCreated":        .other,
        "TaskCompleted":      .sessionEnd,
        "PreCompact":         .other,
        "PostCompact":        .other,
        "FileChanged":        .fileChanged,
        "CwdChanged":         .other,
        "ConfigChange":       .other,
        "InstructionsLoaded": .other,
        "Elicitation":        .agentResponse,
        "ElicitationResult":  .other,
        "WorktreeCreate":     .other,
        "WorktreeRemove":     .other,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        let payload = envelope.payloadDict ?? [:]
        let phase = Self.phaseMap[envelope.event] ?? .other
        let sessionId = (payload["session_id"] as? String) ?? "pid-\(envelope.pid)"
        let tool = payload["tool_name"] as? String ?? payload["tool"] as? String
        let filePath = extractFilePath(from: payload)
        let summary = buildSummary(event: envelope.event, tool: tool, payload: payload)

        return NormalizedHookEvent(
            agent: agent,
            phase: phase,
            rawEvent: envelope.event,
            sessionId: sessionId,
            toolName: tool,
            filePath: filePath,
            cwd: payload["cwd"] as? String ?? envelope.cwd,
            timestamp: Date(timeIntervalSince1970: envelope.ts),
            summary: summary,
            isFatal: envelope.event == "StopFailure",
            payloadRaw: envelope.payloadRaw
        )
    }
}

// MARK: - Cursor normalizer

struct CursorEventNormalizer: AgentEventNormalizer {
    let agent = TrackedAgent.cursor

    private static let phaseMap: [String: NormalizedEventPhase] = [
        "sessionStart":           .sessionStart,
        "sessionEnd":             .sessionEnd,
        "preToolUse":             .toolStart,
        "postToolUse":            .toolEnd,
        "postToolUseFailure":     .toolError,
        "subagentStart":          .subagentStart,
        "subagentStop":           .subagentEnd,
        "beforeShellExecution":   .toolStart,
        "afterShellExecution":    .toolEnd,
        "beforeMCPExecution":     .toolStart,
        "afterMCPExecution":      .toolEnd,
        "afterFileEdit":          .fileChanged,
        "beforeReadFile":         .other,
        "beforeSubmitPrompt":     .userPrompt,
        "preCompact":             .other,
        "stop":                   .sessionEnd,
        "afterAgentResponse":     .agentResponse,
        "afterAgentThought":      .other,
        "beforeTabFileRead":      .other,
        "afterTabFileEdit":       .fileChanged,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        let payload = envelope.payloadDict ?? [:]
        let phase = Self.phaseMap[envelope.event] ?? .other
        // Cursor uses conversation_id, then session_id, then generation_id
        let sessionId = (payload["conversation_id"] as? String)
            ?? (payload["session_id"] as? String)
            ?? (payload["generation_id"] as? String)
            ?? "pid-\(envelope.pid)"
        let tool = payload["tool_name"] as? String ?? payload["tool"] as? String
        let filePath = extractFilePath(from: payload)
        let summary = buildSummary(event: envelope.event, tool: tool, payload: payload)

        return NormalizedHookEvent(
            agent: agent,
            phase: phase,
            rawEvent: envelope.event,
            sessionId: sessionId,
            toolName: tool,
            filePath: filePath,
            cwd: payload["cwd"] as? String ?? envelope.cwd,
            timestamp: Date(timeIntervalSince1970: envelope.ts),
            summary: summary,
            isFatal: false,
            payloadRaw: envelope.payloadRaw
        )
    }
}

// MARK: - VS Code Copilot normalizer

struct VSCodeEventNormalizer: AgentEventNormalizer {
    let agent = TrackedAgent.vscode

    private static let phaseMap: [String: NormalizedEventPhase] = [
        "SessionStart":       .sessionStart,
        "SessionEnd":         .sessionEnd,
        "PreToolUse":         .toolStart,
        "PostToolUse":        .toolEnd,
        "PostToolUseFailure": .toolError,
        "PermissionRequest":  .permissionNeeded,
        "Stop":               .sessionEnd,
        "SubagentStart":      .subagentStart,
        "SubagentStop":       .subagentEnd,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        let payload = envelope.payloadDict ?? [:]
        let phase = Self.phaseMap[envelope.event] ?? .other
        // VS Code uses camelCase sessionId
        let sessionId = (payload["sessionId"] as? String)
            ?? (payload["session_id"] as? String)
            ?? "pid-\(envelope.pid)"
        let tool = payload["tool_name"] as? String ?? payload["tool"] as? String
        let filePath = extractFilePath(from: payload)
        let summary = buildSummary(event: envelope.event, tool: tool, payload: payload)

        return NormalizedHookEvent(
            agent: agent,
            phase: phase,
            rawEvent: envelope.event,
            sessionId: sessionId,
            toolName: tool,
            filePath: filePath,
            cwd: payload["cwd"] as? String ?? envelope.cwd,
            timestamp: Date(timeIntervalSince1970: envelope.ts),
            summary: summary,
            isFatal: false,
            payloadRaw: envelope.payloadRaw
        )
    }
}

// MARK: - Copilot CLI normalizer

struct CopilotCLIEventNormalizer: AgentEventNormalizer {
    let agent = TrackedAgent.copilotCLI

    private static let phaseMap: [String: NormalizedEventPhase] = [
        "sessionStart":         .sessionStart,
        "sessionEnd":           .sessionEnd,
        "userPromptSubmitted":  .userPrompt,
        "preToolUse":           .toolStart,
        "postToolUse":          .toolEnd,
        "errorOccurred":        .error,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        let payload = envelope.payloadDict ?? [:]
        let phase = Self.phaseMap[envelope.event] ?? .other
        let sessionId = (payload["session_id"] as? String) ?? "pid-\(envelope.pid)"
        let tool = payload["tool_name"] as? String ?? payload["tool"] as? String
        let filePath = extractFilePath(from: payload)
        let summary = buildSummary(event: envelope.event, tool: tool, payload: payload)

        return NormalizedHookEvent(
            agent: agent,
            phase: phase,
            rawEvent: envelope.event,
            sessionId: sessionId,
            toolName: tool,
            filePath: filePath,
            cwd: payload["cwd"] as? String ?? envelope.cwd,
            timestamp: Date(timeIntervalSince1970: envelope.ts),
            summary: summary,
            isFatal: envelope.event == "errorOccurred",
            payloadRaw: envelope.payloadRaw
        )
    }
}

// MARK: - Normalizer registry

enum EventNormalizerRegistry {
    private static let normalizers: [TrackedAgent: any AgentEventNormalizer] = [
        .claude:     ClaudeEventNormalizer(),
        .cursor:     CursorEventNormalizer(),
        .vscode:     VSCodeEventNormalizer(),
        .copilotCLI: CopilotCLIEventNormalizer(),
    ]

    static func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        guard let agent = TrackedAgent(rawValue: envelope.agent) else { return nil }
        return normalizers[agent]?.normalize(envelope: envelope)
    }
}

// MARK: - Shared helpers

private func extractFilePath(from payload: [String: Any]) -> String? {
    (payload["file_path"] as? String)
    ?? (payload["input"] as? [String: Any])?["file_path"] as? String
}

private func buildSummary(event: String, tool: String?, payload: [String: Any]) -> String {
    if let tool {
        if let filePath = extractFilePath(from: payload) {
            return "\(tool): \(URL(fileURLWithPath: filePath).lastPathComponent)"
        }
        return tool
    }
    return event
}
