import Foundation

// Claude Code tracker. Owns the full Claude hook surface:
//   - 25 native events (PascalCase) — see AgentInstallerV2.claudeEvents
//   - Session identity via payload["session_id"] (fallback: pid-N)
//   - Tool name via payload["tool_name"] or payload["tool"]
//   - Interaction tools (AskUserQuestion/ExitPlanMode/Elicitation) mapped
//     to `.permissionNeeded` regardless of base event mapping
//   - Notification[permission_prompt/idle_prompt/elicitation_dialog]
//     mapped to `.permissionNeeded`
//   - StopFailure is the only fatal event
//
// Ref: Ref/Claude-code-hooks.md

struct ClaudeTracker: AgentTracker {
    let agent = TrackedAgent.claude

    /// Interaction tools (exact-match). NEVER substring-match here —
    /// `Task` contains `ask` which would mis-flag every subagent dispatch.
    static let interactionTools: Set<String> = [
        "AskUserQuestion",
        "ExitPlanMode",
        "Elicitation",
    ]

    /// Notification subtypes that signal Claude is awaiting the user.
    static let interactionNotificationTypes: Set<String> = [
        "permission_prompt",
        "idle_prompt",
        "elicitation_dialog",
    ]

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
        "TeammateIdle":       .other,
        "PreCompact":         .other,
        "PostCompact":        .other,
        "FileChanged":        .fileChanged,
        "CwdChanged":         .other,
        "ConfigChange":       .other,
        "InstructionsLoaded": .other,
        "Elicitation":        .permissionNeeded,
        "ElicitationResult":  .other,
        "WorktreeCreate":     .other,
        "WorktreeRemove":     .other,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent {
        let payload = envelope.payloadDict ?? [:]
        var phase = Self.phaseMap[envelope.event] ?? .other

        // PreToolUse for interaction tools = waiting on user.
        if envelope.event == "PreToolUse",
           let toolName = payload["tool_name"] as? String,
           Self.interactionTools.contains(toolName) {
            phase = .permissionNeeded
        }
        // Notification with permission/idle/elicitation subtype = waiting.
        if envelope.event == "Notification",
           let notifType = payload["notification_type"] as? String,
           Self.interactionNotificationTypes.contains(notifType) {
            phase = .permissionNeeded
        }

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
