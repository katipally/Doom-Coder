import Foundation

// Windsurf Cascade tracker. Owns the full Cascade hook surface:
//   - 12 native events (snake_case) — see AgentInstallerV2.windsurfEvents
//   - Session identity via payload["trajectory_id"] (the conversation),
//     NOT execution_id (a single turn)
//   - Tool metadata nested under payload["tool_info"]
//   - Both post_cascade_response and post_cascade_response_with_transcript
//     fire at end-of-turn. We treat the former as `.sessionEnd` (so a
//     "done" notification fires) and the latter stays as `.agentResponse`
//     so it doesn't generate a duplicate notification.
//   - pre_mcp_tool_use can require user approval per Windsurf docs — we
//     map it to `.permissionNeeded` for safety. If the user has rule-
//     approved an MCP tool, no UI surfaces; the notification toggle in
//     prefs lets them suppress it.
//
// Ref: Ref/Windsurf-hooks.md

struct WindsurfTracker: AgentTracker {
    let agent = TrackedAgent.windsurf

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

    private func toolName(event: String, toolInfo: [String: Any]) -> String? {
        switch event {
        case "pre_write_code", "post_write_code":
            return "Write"
        case "pre_read_code", "post_read_code":
            return "Read"
        case "pre_run_command", "post_run_command":
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

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent {
        let payload = envelope.payloadDict ?? [:]
        let phase = Self.phaseMap[envelope.event] ?? .other
        let sessionId = (payload["trajectory_id"] as? String) ?? "pid-\(envelope.pid)"
        let toolInfo = payload["tool_info"] as? [String: Any] ?? [:]
        let filePath = toolInfo["file_path"] as? String
        let tool = toolName(event: envelope.event, toolInfo: toolInfo)
        let summary = buildSummary(event: envelope.event, tool: tool, payload: payload)

        // post_cascade_response → sessionEnd ("done" notification).
        // post_cascade_response_with_transcript stays as agentResponse to
        // prevent a duplicate "done" alert.
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
            summary: summary,
            isFatal: false,
            payloadRaw: envelope.payloadRaw
        )
    }
}
