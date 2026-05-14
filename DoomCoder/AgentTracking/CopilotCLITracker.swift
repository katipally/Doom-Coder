import Foundation

// GitHub Copilot CLI tracker. Owns the full Copilot CLI hook surface:
//   - 6 native events (camelCase) — see AgentInstallerV2.copilotCLIEvents
//   - Repo-scoped config at <repo>/.github/hooks/doomcoder.json (this is
//     why v2.3.0 also ships .gitignore + folder-exclusion changes)
//   - errorOccurred fires for BOTH real errors AND clean exits
//     (Ctrl+C, SIGTERM, quit). We inspect payload for clean-exit signals
//     and downgrade to `.sessionEnd` to avoid scary "failed" notifications.
//
// Ref: Ref/Copilot-cli-hooks.md

struct CopilotCLITracker: AgentTracker {
    let agent = TrackedAgent.copilotCLI

    private static let phaseMap: [String: NormalizedEventPhase] = [
        "sessionStart":         .sessionStart,
        "sessionEnd":           .sessionEnd,
        "userPromptSubmitted":  .userPrompt,
        "preToolUse":           .toolStart,
        "postToolUse":          .toolEnd,
        "errorOccurred":        .error,
    ]

    /// Clean-exit detection for the errorOccurred event. Returns true
    /// when the payload indicates the user terminated the session
    /// normally (Ctrl+C, signal, exit code 0/130/143). When true, the
    /// event is reclassified as `.sessionEnd` so notifications use the
    /// "done" copy template instead of "failed".
    private static func isCleanExit(payload: [String: Any]) -> Bool {
        if payload["is_user_interrupt"] as? Bool == true { return true }
        if let signal = payload["signal"] as? String,
           ["SIGINT", "SIGTERM", "SIGHUP"].contains(signal) { return true }
        if (payload["exit_reason"] as? String) == "user_exit" { return true }
        if let errorType = payload["error_type"] as? String,
           ["interrupt", "exit", "close", "cancelled"].contains(errorType) { return true }
        if let code = payload["exit_code"] as? Int, [0, 130, 143].contains(code) { return true }
        return false
    }

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent {
        let payload = envelope.payloadDict ?? [:]
        var phase = Self.phaseMap[envelope.event] ?? .other
        var isFatal = false

        if envelope.event == "errorOccurred" {
            if Self.isCleanExit(payload: payload) {
                phase = .sessionEnd
            } else {
                phase = .error
                isFatal = true
            }
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
            isFatal: isFatal,
            payloadRaw: envelope.payloadRaw
        )
    }
}
