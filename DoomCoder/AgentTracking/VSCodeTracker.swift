import Foundation

// VS Code Copilot tracker. Owns the full VS Code hook surface:
//   - 8 native events (PascalCase, matcher-group style)
//   - VS Code shares ~/.claude/settings.json with Claude — dc-hook's
//     `vscode` agent token disambiguates at envelope time, so this
//     tracker only ever receives true VS Code events.
//   - Session identity: sessionId → session_id → pid-N
//   - VS Code-specific interaction tools cover Quick Pick / Input Box.
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
            isFatal: false,
            payloadRaw: envelope.payloadRaw
        )
    }
}
