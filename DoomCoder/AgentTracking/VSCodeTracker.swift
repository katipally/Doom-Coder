import Foundation

// VS Code Copilot tracker. Owns the full VS Code hook surface:
//   - All 29 Claude Code events (PascalCase, matcher-group style)
//   - VS Code currently fires 8 events natively; additional events are
//     registered so DoomCoder automatically captures them as VS Code
//     expands its hook support (it's still in Preview).
//   - Hooks live at ~/.copilot/hooks/hooks.json — same file as Copilot CLI
//     user-level hooks, which coexist via case-sensitive camelCase keys.
//   - Session identity: sessionId → session_id → pid-N
//
// Ref: Ref/VScode-agent-hooks.md

struct VSCodeTracker: AgentTracker {
    let agent = TrackedAgent.vscode

    static let interactionTools: Set<String> = [
        "vscode_askQuestions",
        "vscode_getQuickPick",
        "vscode_getInputBox",
        "vscode_showConfirmation",
    ]

    private static let phaseMap: [String: NormalizedEventPhase] = [
        // Session lifecycle
        "SessionStart":        .sessionStart,
        "Setup":               .sessionStart,
        "SessionEnd":          .sessionEnd,
        "Stop":                .sessionEnd,
        "StopFailure":         .error,
        // Prompts
        "UserPromptSubmit":    .userPrompt,
        "UserPromptExpansion": .userPrompt,
        // Tools
        "PreToolUse":          .toolStart,
        "PostToolUse":         .toolEnd,
        "PostToolUseFailure":  .toolError,
        "PostToolBatch":       .toolEnd,
        // Permissions & elicitation
        "PermissionRequest":   .permissionNeeded,
        "PermissionDenied":    .permissionNeeded,
        "Elicitation":         .permissionNeeded,
        "ElicitationResult":   .other,
        // Notifications
        "Notification":        .agentResponse,
        // Sub-agents
        "SubagentStart":       .subagentStart,
        "SubagentStop":        .subagentEnd,
        "TeammateIdle":        .other,
        // Tasks
        "TaskCreated":         .other,
        "TaskCompleted":       .other,
        // Context & config
        "PreCompact":          .other,
        "PostCompact":         .other,
        "FileChanged":         .fileChanged,
        "CwdChanged":          .other,
        "ConfigChange":        .other,
        "InstructionsLoaded":  .other,
        // Setup
        "WorktreeCreate":      .other,
        "WorktreeRemove":      .other,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent {
        let payload = envelope.payloadDict ?? [:]
        var phase = Self.phaseMap[envelope.event] ?? .other

        if envelope.event == "PreToolUse",
           let toolName = payload["tool_name"] as? String,
           Self.interactionTools.contains(toolName) {
            phase = .permissionNeeded
        }

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
            isFatal: envelope.event == "StopFailure",
            payloadRaw: envelope.payloadRaw
        )
    }
}
