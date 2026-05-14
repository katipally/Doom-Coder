import Foundation

// Cursor tracker. Owns the full Cursor hook surface:
//   - 20 native events (camelCase) — see AgentInstallerV2.cursorEvents
//   - Session identity preference: conversation_id → session_id →
//     generation_id → pid-N
//   - Both shell-execution and MCP-execution pre/post events map to
//     tool start/end so the active tool counter reflects them
//   - Interaction tools (AskUserQuestion/ExitPlanMode) on preToolUse map
//     to `.permissionNeeded`
//
// Ref: Ref/cursor-hooks.md

struct CursorTracker: AgentTracker {
    let agent = TrackedAgent.cursor

    static let interactionTools: Set<String> = [
        "AskUserQuestion",
        "ExitPlanMode",
    ]

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

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent {
        let payload = envelope.payloadDict ?? [:]
        var phase = Self.phaseMap[envelope.event] ?? .other

        if envelope.event == "preToolUse",
           let toolName = payload["tool_name"] as? String,
           Self.interactionTools.contains(toolName) {
            phase = .permissionNeeded
        }

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
