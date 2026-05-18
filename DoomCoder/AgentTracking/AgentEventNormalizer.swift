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
    let isFatal: Bool
    let payloadRaw: Data?
}

// MARK: - Per-agent normalizer protocol

protocol AgentEventNormalizer: Sendable {
    var agent: TrackedAgent { get }
    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent?
}

// MARK: - Per-agent interaction tool catalogs
//
// Exact-match only. NO substring matching — `Task` contains `ask`, which used
// to mis-flag every Claude subagent dispatch as `permissionNeeded`. Under-
// notifying on unknown future tools is the correct default for an alerting
// product; once a real interaction tool is observed it can be added here.

private let claudeInteractionTools: Set<String> = [
    "AskUserQuestion",
    "ExitPlanMode",
    "Elicitation",
]

private let cursorInteractionTools: Set<String> = [
    "AskUserQuestion",
    "ExitPlanMode",
]

private let vscodeInteractionTools: Set<String> = [
    "vscode_askQuestions",
    "vscode_getQuickPick",
    "vscode_getInputBox",
    "vscode_showConfirmation",
]

private let copilotCLIInteractionTools: Set<String> = []
private let windsurfInteractionTools:   Set<String> = []
private let codexInteractionTools:      Set<String> = []

// MARK: - Claude Code normalizer

struct ClaudeEventNormalizer: AgentEventNormalizer {
    let agent = TrackedAgent.claude

    private static let phaseMap: [String: NormalizedEventPhase] = [
        "SessionStart":          .sessionStart,
        "SessionEnd":            .sessionEnd,
        "UserPromptSubmit":      .userPrompt,
        "UserPromptExpansion":   .userPrompt,
        "PreToolUse":            .toolStart,
        "PostToolUse":           .toolEnd,
        "PostToolUseFailure":    .toolError,
        "PostToolBatch":         .toolEnd,
        "PermissionRequest":     .permissionNeeded,
        "PermissionDenied":      .permissionNeeded,
        "Notification":          .agentResponse,
        "Stop":                  .sessionEnd,
        "StopFailure":           .error,
        "SubagentStart":         .subagentStart,
        "SubagentStop":          .subagentEnd,
        "TaskCreated":           .other,
        "TaskCompleted":         .sessionEnd,
        "TeammateIdle":          .other,
        "PreCompact":            .other,
        "PostCompact":           .other,
        "FileChanged":           .other,
        "CwdChanged":            .other,
        "ConfigChange":          .other,
        "InstructionsLoaded":    .other,
        "Elicitation":           .permissionNeeded,
        "ElicitationResult":     .other,
        "WorktreeCreate":        .other,
        "WorktreeRemove":        .other,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        let payload = envelope.payloadDict ?? [:]
        var phase = Self.phaseMap[envelope.event] ?? .other

        // PreToolUse[AskUserQuestion/ExitPlanMode] = agent waiting for user answer
        if envelope.event == "PreToolUse",
           let toolName = payload["tool_name"] as? String,
           claudeInteractionTools.contains(toolName) {
            phase = .permissionNeeded
        }
        if envelope.event == "Notification",
           let notifType = payload["notification_type"] as? String,
           ["permission_prompt", "idle_prompt", "elicitation_dialog"].contains(notifType) {
            phase = .permissionNeeded
        }

        let sessionId = (payload["session_id"] as? String) ?? "pid-\(envelope.pid)"
        let tool = payload["tool_name"] as? String ?? payload["tool"] as? String
        let filePath = extractFilePath(from: payload)

        return NormalizedHookEvent(
            agent: agent,
            phase: phase,
            rawEvent: envelope.event,
            sessionId: sessionId,
            toolName: tool,
            filePath: filePath,
            cwd: payload["cwd"] as? String ?? envelope.cwd,
            timestamp: Date(timeIntervalSince1970: envelope.ts),
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
        "afterFileEdit":          .other,
        "beforeReadFile":         .other,
        "beforeSubmitPrompt":     .userPrompt,
        "preCompact":             .other,
        "stop":                   .sessionEnd,
        "afterAgentResponse":     .agentResponse,
        "afterAgentThought":      .other,
        "beforeTabFileRead":      .other,
        "afterTabFileEdit":       .other,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        let payload = envelope.payloadDict ?? [:]
        var phase = Self.phaseMap[envelope.event] ?? .other

        if envelope.event == "preToolUse",
           let toolName = payload["tool_name"] as? String,
           cursorInteractionTools.contains(toolName) {
            phase = .permissionNeeded
        }

        // Cursor uses conversation_id, then session_id, then generation_id
        let sessionId = (payload["conversation_id"] as? String)
            ?? (payload["session_id"] as? String)
            ?? (payload["generation_id"] as? String)
            ?? "pid-\(envelope.pid)"
        let tool = payload["tool_name"] as? String ?? payload["tool"] as? String
        let filePath = extractFilePath(from: payload)

        return NormalizedHookEvent(
            agent: agent,
            phase: phase,
            rawEvent: envelope.event,
            sessionId: sessionId,
            toolName: tool,
            filePath: filePath,
            cwd: payload["cwd"] as? String ?? envelope.cwd,
            timestamp: Date(timeIntervalSince1970: envelope.ts),
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
        "UserPromptSubmit":   .userPrompt,
        "PreToolUse":         .toolStart,
        "PostToolUse":        .toolEnd,
        "PostToolUseFailure": .toolError,
        "PermissionRequest":  .permissionNeeded,
        "Stop":               .sessionEnd,
        "SubagentStart":      .subagentStart,
        "SubagentStop":       .subagentEnd,
        "PreCompact":         .other,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        let payload = envelope.payloadDict ?? [:]
        var phase = Self.phaseMap[envelope.event] ?? .other

        if envelope.event == "PreToolUse",
           let toolName = payload["tool_name"] as? String,
           vscodeInteractionTools.contains(toolName) {
            phase = .permissionNeeded
        }
        let sessionId = (payload["sessionId"] as? String)
            ?? (payload["session_id"] as? String)
            ?? "pid-\(envelope.pid)"
        let tool = payload["tool_name"] as? String ?? payload["tool"] as? String
        let filePath = extractFilePath(from: payload)

        return NormalizedHookEvent(
            agent: agent,
            phase: phase,
            rawEvent: envelope.event,
            sessionId: sessionId,
            toolName: tool,
            filePath: filePath,
            cwd: payload["cwd"] as? String ?? envelope.cwd,
            timestamp: Date(timeIntervalSince1970: envelope.ts),
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
        var phase = Self.phaseMap[envelope.event] ?? .other
        var isFatal = false

        // errorOccurred fires for BOTH real errors and clean user exits (Ctrl+C, SIGTERM).
        // Check payload for clean-exit signals before treating it as a fatal error.
        if envelope.event == "errorOccurred" {
            let isCleanExit: Bool = {
                if payload["is_user_interrupt"] as? Bool == true { return true }
                let signal = payload["signal"] as? String ?? ""
                if ["SIGINT", "SIGTERM", "SIGHUP"].contains(signal) { return true }
                let exitReason = payload["exit_reason"] as? String ?? ""
                if exitReason == "user_exit" { return true }
                let errorType = payload["error_type"] as? String ?? ""
                if ["interrupt", "exit", "close", "cancelled"].contains(errorType) { return true }
                // Unix exit codes: 0=clean, 130=SIGINT (Ctrl+C), 143=SIGTERM
                if let code = payload["exit_code"] as? Int, [0, 130, 143].contains(code) { return true }
                return false
            }()
            if isCleanExit {
                phase = .sessionEnd   // treat as normal close — suppress error notification
            } else {
                phase = .error
                isFatal = true
            }
        }

        let sessionId = (payload["session_id"] as? String) ?? "pid-\(envelope.pid)"
        let tool = payload["tool_name"] as? String ?? payload["tool"] as? String
        let filePath = extractFilePath(from: payload)

        return NormalizedHookEvent(
            agent: agent,
            phase: phase,
            rawEvent: envelope.event,
            sessionId: sessionId,
            toolName: tool,
            filePath: filePath,
            cwd: payload["cwd"] as? String ?? envelope.cwd,
            timestamp: Date(timeIntervalSince1970: envelope.ts),
            isFatal: isFatal,
            payloadRaw: envelope.payloadRaw
        )
    }
}

// MARK: - Windsurf Cascade normalizer

struct WindsurfEventNormalizer: AgentEventNormalizer {
    let agent = TrackedAgent.windsurf

    // Windsurf uses snake_case pre/post event names.
    // trajectory_id is the session identity; execution_id is the turn identity.
    private static let phaseMap: [String: NormalizedEventPhase] = [
        "pre_read_code":                           .toolStart,
        "post_read_code":                          .toolEnd,
        "pre_write_code":                          .toolStart,
        "post_write_code":                         .toolEnd,
        "pre_run_command":                         .toolStart,
        "post_run_command":                        .toolEnd,
        "pre_mcp_tool_use":                        .permissionNeeded,
        "post_mcp_tool_use":                       .toolEnd,
        "pre_user_prompt":                         .userPrompt,
        "post_cascade_response":                   .agentResponse,
        "post_cascade_response_with_transcript":   .agentResponse,
        "post_setup_worktree":                     .other,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        let payload = envelope.payloadDict ?? [:]
        let phase = Self.phaseMap[envelope.event] ?? .other
        // Windsurf uses trajectory_id for the conversation session
        let sessionId = (payload["trajectory_id"] as? String) ?? "pid-\(envelope.pid)"
        // Tool info is nested under tool_info object
        let toolInfo = payload["tool_info"] as? [String: Any] ?? [:]
        let filePath = toolInfo["file_path"] as? String
        let tool = windsurfToolName(event: envelope.event, toolInfo: toolInfo)

        // post_cascade_response marks end-of-turn → sessionEnd ("done" notification).
        // post_cascade_response_with_transcript fires immediately after as a superset;
        // keeping it as agentResponse (notifications off) prevents a duplicate "done" alert.
        let effectivePhase: NormalizedEventPhase =
            (envelope.event == "post_cascade_response") ? .sessionEnd : phase

        return NormalizedHookEvent(
            agent: agent,
            phase: effectivePhase,
            rawEvent: envelope.event,
            sessionId: sessionId,
            toolName: tool,
            filePath: filePath,
            cwd: toolInfo["cwd"] as? String ?? envelope.cwd,
            timestamp: Date(timeIntervalSince1970: envelope.ts),
            isFatal: false,
            payloadRaw: envelope.payloadRaw
        )
    }

    private func windsurfToolName(event: String, toolInfo: [String: Any]) -> String? {
        switch event {
        case "pre_write_code", "post_write_code":
            return "Write"
        case "pre_read_code", "post_read_code":
            return "Read"
        case "pre_run_command", "post_run_command":
            // Show the actual command if available (truncated for display)
            if let cmd = toolInfo["command_line"] as? String {
                return String(cmd.prefix(60))
            }
            return "Bash"
        case "pre_mcp_tool_use", "post_mcp_tool_use":
            return toolInfo["mcp_tool_name"] as? String ?? "MCP"
        default:
            return nil
        }
    }
}

// MARK: - OpenAI Codex CLI normalizer

struct CodexCLIEventNormalizer: AgentEventNormalizer {
    let agent = TrackedAgent.codexCLI

    private static let phaseMap: [String: NormalizedEventPhase] = [
        "SessionStart":       .sessionStart,
        "UserPromptSubmit":   .userPrompt,
        "PreToolUse":         .toolStart,
        "PostToolUse":        .toolEnd,
        "PermissionRequest":  .permissionNeeded,
        "Stop":               .sessionEnd,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        let payload = envelope.payloadDict ?? [:]
        let phase = Self.phaseMap[envelope.event] ?? .other

        let sessionId = (payload["session_id"] as? String)
            ?? (payload["conversation_id"] as? String)
            ?? "pid-\(envelope.pid)"
        let tool = payload["tool_name"] as? String ?? payload["tool"] as? String
        let filePath = extractFilePath(from: payload)

        return NormalizedHookEvent(
            agent: agent,
            phase: phase,
            rawEvent: envelope.event,
            sessionId: sessionId,
            toolName: tool,
            filePath: filePath,
            cwd: payload["cwd"] as? String ?? envelope.cwd,
            timestamp: Date(timeIntervalSince1970: envelope.ts),
            isFatal: phase == .error,
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
        .windsurf:   WindsurfEventNormalizer(),
        .codexCLI:   CodexCLIEventNormalizer(),
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
