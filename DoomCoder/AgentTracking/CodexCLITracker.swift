import Foundation

// OpenAI Codex CLI tracker. Owns the full Codex hook surface:
//   - 6 native events (PascalCase, same shape as Claude matcher-group)
//   - Requires `[features] codex_hooks = true` in ~/.codex/config.toml
//     (handled by AgentInstallerV2.ensureCodexFeatureFlag)
//   - SessionStart hook is matched with `startup|resume` so it does NOT
//     fire on conversation clear (`source = clear`)
//   - Session identity: session_id → conversation_id → pid-N
//
// Ref: Ref/Codex-hooks.md

struct CodexCLITracker: AgentTracker {
    let agent = TrackedAgent.codexCLI

    static let interactionTools: Set<String> = []

    private static let phaseMap: [String: NormalizedEventPhase] = [
        "SessionStart":       .sessionStart,
        "UserPromptSubmit":   .userPrompt,
        "PreToolUse":         .toolStart,
        "PostToolUse":        .toolEnd,
        "PermissionRequest":  .permissionNeeded,
        "Stop":               .sessionEnd,
    ]

    func normalize(envelope: HookEnvelope) -> NormalizedHookEvent {
        let payload = envelope.payloadDict ?? [:]
        var phase = Self.phaseMap[envelope.event] ?? .other

        if envelope.event == "PreToolUse",
           let toolName = payload["tool_name"] as? String,
           Self.interactionTools.contains(toolName) {
            phase = .permissionNeeded
        }
        if envelope.event.lowercased().contains("error") { phase = .error }

        let sessionId = (payload["session_id"] as? String)
            ?? (payload["conversation_id"] as? String)
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
            isFatal: phase == .error,
            payloadRaw: envelope.payloadRaw
        )
    }
}
