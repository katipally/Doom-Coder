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
    // Opt-in coverage phases (default OFF in the gate). MUST stay byte-identical
    // to the Core enum (Packages/DoomCodeCore/.../NormalizedEventPhase.swift)
    // because CloudKit serializes the rawValue String.
    case fileEdit
    case compaction
    case thinking
    case housekeeping
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

private let cursorPermissionTools: Set<String> = [
    "Shell", "Write", "Edit", "Delete"
]

/// Returns true when the tool name matches a Cursor-native action whose
/// invocation would normally prompt the user, or any MCP tool (prefix
/// "MCP:"). Reserved for future use — Plan A+ relies on the dedicated
/// beforeShellExecution / beforeMCPExecution events for the permission
/// signal; this predicate is kept so a future preToolUse-only build of
/// Cursor (or a payload without dedicated events) can still classify
/// tools without resurrecting the old Claude-style heuristic.
@inline(__always)
private func isCursorPermissionTool(_ name: String) -> Bool {
    if cursorPermissionTools.contains(name) { return true }
    if name.hasPrefix("MCP:") { return true }
    return false
}

private let vscodeInteractionTools: Set<String> = [
    "vscode_askQuestions",
    "vscode_getQuickPick",
    "vscode_getInputBox",
    "vscode_showConfirmation",
]

private let copilotCLIInteractionTools: Set<String> = [
    "ask_user",        // agent asking you a question mid-task
    "exit_plan_mode",  // agent needs your approval on a plan
]
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
        "TaskCreated":           .housekeeping,
        "TaskCompleted":         .housekeeping,
        "TeammateIdle":          .housekeeping,
        "PreCompact":            .compaction,
        "PostCompact":           .compaction,
        "FileChanged":           .fileEdit,
        "CwdChanged":            .housekeeping,
        "ConfigChange":          .housekeeping,
        "InstructionsLoaded":    .housekeeping,
        "Elicitation":           .permissionNeeded,
        "ElicitationResult":     .other,
        "WorktreeCreate":        .housekeeping,
        "WorktreeRemove":        .housekeeping,
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
        // idle_prompt means Claude finished and is waiting for the user's NEXT message.
        // It is NOT a permission request — map it to agentResponse (silent by default)
        // so users don't receive a spurious "needs you" alert after the "done" notification.
        if envelope.event == "Notification",
           let notifType = payload["notification_type"] as? String,
           ["permission_prompt", "elicitation_dialog"].contains(notifType) {
            phase = .permissionNeeded
        }

        // Defense-in-depth: sessions whose cwd equals the user's HOME directory are
        // Claude Desktop internal sessions (startup probes, spare sessions). These fire
        // SessionEnd/Stop immediately after opening Claude Desktop and produce spurious
        // "Finished in <username>" notifications. dc-hook filters them at the process
        // level (dc-hook inherits the session's cwd); this guard catches any that slip
        // through at the app layer by inspecting the cwd field in the hook payload.
        // A real user coding session always has a project directory, never bare HOME.
        if phase == .sessionEnd {
            let eventCwd = payload["cwd"] as? String ?? envelope.cwd
            let home     = NSHomeDirectory()
            if !eventCwd.isEmpty && !home.isEmpty && eventCwd == home {
                phase = .other   // record the event, but fire no "Finished" notification
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
        "beforeShellExecution":   .permissionNeeded,
        "afterShellExecution":    .toolEnd,
        "beforeMCPExecution":     .permissionNeeded,
        "afterMCPExecution":      .toolEnd,
        "afterFileEdit":          .fileEdit,
        "beforeReadFile":         .other,
        "beforeSubmitPrompt":     .userPrompt,
        "preCompact":             .compaction,
        "stop":                   .sessionEnd,
        "afterAgentResponse":     .agentResponse,
        "afterAgentThought":      .thinking,
        "beforeTabFileRead":      .other,
        "afterTabFileEdit":       .fileEdit,
        "workspaceOpen":          .housekeeping,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        let payload = envelope.payloadDict ?? [:]
        var phase = Self.phaseMap[envelope.event] ?? .other
        var isFatal = false

        // Payload-status dispatch (Plan A+): use Cursor's native differentiation
        // fields rather than heuristics. status="error" => fatal failure,
        // "aborted"/"completed" => clean session end.
        switch envelope.event {
        case "stop", "sessionEnd":
            let status = (payload["status"] as? String) ?? (payload["reason"] as? String)
            if status == "error" {
                phase = .error
                isFatal = true
            } else {
                phase = .sessionEnd
            }
        case "subagentStop":
            if (payload["status"] as? String) == "error" {
                phase = .toolError
            } else {
                phase = .subagentEnd
            }
        case "postToolUseFailure":
            phase = .toolError
        default:
            // For Shell/Write/Edit/Delete/MCP:* preToolUse calls, prefer the
            // dedicated beforeShellExecution / beforeMCPExecution events for
            // the permission signal. preToolUse stays at .toolStart.
            break
        }

        // Cursor uses conversation_id, then session_id, then generation_id
        let sessionId = (payload["conversation_id"] as? String)
            ?? (payload["session_id"] as? String)
            ?? (payload["generation_id"] as? String)
            ?? "pid-\(envelope.pid)"
        let tool = payload["tool_name"] as? String ?? payload["tool"] as? String
        let filePath = extractFilePath(from: payload)

        // Suppress noisy permission-needed flag on tools we know Cursor won't
        // actually prompt for. The predicate `isCursorPermissionTool` is
        // available for future heuristics; today only the dedicated
        // beforeShellExecution/beforeMCPExecution events emit .permissionNeeded.
        _ = isCursorPermissionTool

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
        "PreCompact":         .compaction,
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
        "postToolUseFailure":   .toolError,
        "agentStop":            .sessionEnd,
        "subagentStart":        .subagentStart,
        "subagentStop":         .subagentEnd,
        "errorOccurred":        .error,
        "preCompact":           .compaction,
        "permissionRequest":    .permissionNeeded,
        // `notification` is dispatched by notification_type in normalize().
        "notification":         .other,
    ]

    /// Sub-mapping for Copilot CLI's `notification` event — the per-turn
    /// idle/done signal, equivalent to Claude's `Notification` hook. The
    /// CLI sends a `notification_type` discriminator in the payload.
    private static let notificationTypeMap: [String: NormalizedEventPhase] = [
        "shell_completed":          .toolEnd,
        "shell_detached_completed": .toolEnd,
        "agent_completed":          .subagentEnd,
        "agent_idle":               .sessionEnd,
        "permission_prompt":        .permissionNeeded,
        "elicitation_dialog":       .permissionNeeded,
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

        // `notification` is the per-turn idle/done signal — equivalent to
        // Claude's `Notification` hook. Dispatch on notification_type so we
        // map agent_idle → sessionEnd (fires "done" toast) and
        // permission_prompt → permissionNeeded.
        if envelope.event == "notification" {
            let kind = payload["notification_type"] as? String ?? ""
            phase = Self.notificationTypeMap[kind] ?? .other
        }

        // Copilot CLI sends camelCase field names; fall back to snake_case for
        // forward-compatibility in case a future release switches conventions.
        let sessionId = (payload["sessionId"] as? String)
            ?? (payload["session_id"] as? String)
            ?? "pid-\(envelope.pid)"
        let tool = payload["toolName"] as? String
            ?? payload["tool_name"] as? String
            ?? payload["tool"] as? String
        let filePath = extractFilePath(from: payload)

        // preToolUse + interaction tool → agent is waiting for the user's
        // answer or plan approval. Promote to permissionNeeded so a
        // notification fires (same pattern as Claude/VS Code normalizers).
        if envelope.event == "preToolUse",
           let toolName = tool,
           copilotCLIInteractionTools.contains(toolName) {
            phase = .permissionNeeded
        }

        // Belt-and-suspenders: if toolArgs JSON has a "question" key for an
        // otherwise-unknown tool, treat it as an elicitation too.
        if envelope.event == "preToolUse",
           phase == .toolStart,
           let toolArgsStr = payload["toolArgs"] as? String,
           let argsData = toolArgsStr.data(using: .utf8),
           let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
           argsDict["question"] != nil {
            phase = .permissionNeeded
        }

        // permissionRequest allowlist filter: Copilot fires the hook for ALL
        // permission checks, including those the user has pre-approved via
        // ~/.copilot/permissions-config.json. For pre-approved requests Copilot
        // shows no UI, so Doom Coder must not notify either. Suppress by
        // downgrading to .other.
        if envelope.event == "permissionRequest", phase == .permissionNeeded {
            let cwd = payload["cwd"] as? String ?? envelope.cwd
            // Prefer "promptRequest" (user-facing kind like "commands") over
            // the raw "permissionRequest" (which uses "shell" for commands).
            let promptReq = payload["promptRequest"] as? [String: Any]
                ?? payload["permissionRequest"] as? [String: Any]
                ?? [:]
            if !promptReq.isEmpty,
               CopilotPermissionsReader.shared.isAutoApproved(promptRequest: promptReq, cwd: cwd) {
                phase = .other
            }
        }

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
        "post_setup_worktree":                     .housekeeping,
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
        "PreCompact":         .compaction,
        "PostCompact":        .compaction,
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

// MARK: - opencode normalizer
//
// opencode has no shell-command config hooks. The Doom Coder plugin we install
// (~/.config/opencode/plugin/doomcoder.js) forwards a curated set of opencode's
// in-process events to dc-hook with the agent token "opencode". Event names are
// opencode's dotted bus/hook identifiers; payload fields are camelCase
// (`sessionID`, `tool`, `callID`). Works identically for the CLI/TUI and app.

struct OpenCodeEventNormalizer: AgentEventNormalizer {
    let agent = TrackedAgent.opencode

    private static let phaseMap: [String: NormalizedEventPhase] = [
        "session.created":       .sessionStart,
        "session.idle":          .sessionEnd,     // agent finished its turn → "done"
        "session.error":         .error,
        "session.compacted":     .compaction,
        "session.deleted":       .housekeeping,
        "tool.execute.before":   .toolStart,
        "tool.execute.after":    .toolEnd,
        // The two "agent is blocked, waiting on you" signals. opencode gates
        // command/tool execution behind `permission.asked`, and asks the user
        // questions / multiple-choice elicitations via `question.asked`. Both
        // map to permissionNeeded → the "Waiting for approval" notification.
        "permission.asked":      .permissionNeeded,
        "question.asked":        .permissionNeeded,
        "permission.replied":    .housekeeping,    // resolved → clears the wait
        "question.replied":      .housekeeping,
        "question.rejected":     .housekeeping,
        // Forward-compat: core's v2 event names (not emitted by current runtime).
        "permission.v2.asked":   .permissionNeeded,
        "question.v2.asked":     .permissionNeeded,
        "file.edited":           .fileEdit,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent? {
        let payload = envelope.payloadDict ?? [:]
        let phase = Self.phaseMap[envelope.event] ?? .other

        // opencode emits camelCase `sessionID`; tolerate snake_case for safety.
        let sessionId = (payload["sessionID"] as? String)
            ?? (payload["session_id"] as? String)
            ?? (payload["sessionId"] as? String)
            ?? "pid-\(envelope.pid)"
        let tool = (payload["tool"] as? String)
            ?? (payload["tool_name"] as? String)
        // file.edited carries the path under `file`; fall back to common keys.
        let filePath = (payload["file"] as? String)
            ?? (payload["path"] as? String)
            ?? extractFilePath(from: payload)

        return NormalizedHookEvent(
            agent: agent,
            phase: phase,
            rawEvent: envelope.event,
            sessionId: sessionId,
            toolName: tool,
            filePath: filePath,
            cwd: (payload["directory"] as? String) ?? (payload["cwd"] as? String) ?? envelope.cwd,
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
        .opencode:   OpenCodeEventNormalizer(),
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
