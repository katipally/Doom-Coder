import Foundation

// MARK: - Data types

/// One hook event shown in the per-agent notification preferences UI.
struct AgentEventEntry: Identifiable, Sendable {
    /// Stable id for ForEach (unique within the parent section).
    let id: String
    /// Raw event name as emitted in the hook payload (e.g. "SessionEnd").
    let rawEvent: String
    /// Short description of when this event fires for this agent.
    let note: String
}

/// One notification preference row in the per-agent UI.
///
/// `keyPath` drives the Toggle directly — no switch statement required.
struct AgentPhaseSection: Identifiable, @unchecked Sendable {
    let id: String
    let label: String
    let keyPath: WritableKeyPath<ChannelStore.NotificationPrefs, Bool>
    let entries: [AgentEventEntry]
}

// MARK: - Catalog

/// Per-agent notification event catalog.
///
/// Each section maps to exactly one `ChannelStore.NotificationPrefs` Bool field.
/// `entries` lists the raw hook events that fire that phase for the agent,
/// so users see concrete hook names alongside each toggle.
enum AgentEventCatalog {

    /// Non-empty phase sections for `agent`, in display order.
    static func sections(for agent: TrackedAgent) -> [AgentPhaseSection] {
        allSections(for: agent).filter { !$0.entries.isEmpty }
    }

    // MARK: - Per-agent dispatch

    private static func allSections(for agent: TrackedAgent) -> [AgentPhaseSection] {
        switch agent {
        case .claude:     return claudeSections
        case .cursor:     return cursorSections
        case .windsurf:   return windsurfSections
        case .vscode:     return vscodeSections
        case .copilotCLI: return copilotCLISections
        case .codexCLI:   return codexCLISections
        }
    }

    // MARK: Claude Code
    private static let claudeSections: [AgentPhaseSection] = [
        .init(id: "sessionEnd", label: "Session completed", keyPath: \.sessionEnd, entries: [
            .init(id: "cl-se",   rawEvent: "SessionEnd",    note: "Session finished normally"),
            .init(id: "cl-stop", rawEvent: "Stop",          note: "Agent stopped cleanly"),
            .init(id: "cl-tc",   rawEvent: "TaskCompleted", note: "Background sub-task finished"),
        ]),
        .init(id: "error", label: "Errors", keyPath: \.error, entries: [
            .init(id: "cl-sf",   rawEvent: "StopFailure",        note: "Fatal crash — session could not recover"),
            .init(id: "cl-ptuf", rawEvent: "PostToolUseFailure", note: "Tool execution returned an error"),
        ]),
        .init(id: "perm", label: "Permission requests", keyPath: \.permissionNeeded, entries: [
            .init(id: "cl-pr",  rawEvent: "PermissionRequest",
                  note: "Claude requesting access to a resource"),
            .init(id: "cl-pd",  rawEvent: "PermissionDenied",
                  note: "Permission denied — may need your intervention"),
            .init(id: "cl-el",  rawEvent: "Elicitation",
                  note: "Claude paused, waiting for clarification"),
            .init(id: "cl-auq", rawEvent: "PreToolUse → AskUserQuestion",
                  note: "Claude asking you a direct question"),
            .init(id: "cl-idn", rawEvent: "Notification (idle / permission type)",
                  note: "Status notification requiring your attention"),
        ]),
        .init(id: "agentResp", label: "Agent responses", keyPath: \.agentResponse, entries: [
            .init(id: "cl-notif", rawEvent: "Notification",
                  note: "Claude sent a message or status update"),
        ]),
        .init(id: "sessionStart", label: "Session started", keyPath: \.sessionStart, entries: [
            .init(id: "cl-ss", rawEvent: "SessionStart", note: "New Claude Code session began"),
        ]),
        .init(id: "subStart", label: "Sub-agent launched", keyPath: \.subagentStart, entries: [
            .init(id: "cl-sas", rawEvent: "SubagentStart", note: "Background sub-agent launched"),
        ]),
        .init(id: "subEnd", label: "Sub-agent finished", keyPath: \.subagentEnd, entries: [
            .init(id: "cl-sep", rawEvent: "SubagentStop", note: "Sub-agent finished its task"),
        ]),
        .init(id: "toolUse", label: "Tool usage", keyPath: \.toolUse, entries: [
            .init(id: "cl-ptu",  rawEvent: "PreToolUse",  note: "About to invoke a tool (Bash, Edit, Read…)"),
            .init(id: "cl-postu", rawEvent: "PostToolUse", note: "Tool call completed"),
        ]),
    ]

    // MARK: Cursor
    private static let cursorSections: [AgentPhaseSection] = [
        .init(id: "sessionEnd", label: "Session completed", keyPath: \.sessionEnd, entries: [
            .init(id: "cu-se",   rawEvent: "sessionEnd", note: "Conversation session ended"),
            .init(id: "cu-stop", rawEvent: "stop",       note: "Agent stopped cleanly"),
        ]),
        .init(id: "error", label: "Errors", keyPath: \.error, entries: [
            .init(id: "cu-ptuf", rawEvent: "postToolUseFailure",
                  note: "Tool execution returned an error"),
        ]),
        .init(id: "perm", label: "Permission requests", keyPath: \.permissionNeeded, entries: [
            .init(id: "cu-auq", rawEvent: "preToolUse → AskUserQuestion",
                  note: "Cursor asking for your input before continuing"),
            .init(id: "cu-epm", rawEvent: "preToolUse → ExitPlanMode",
                  note: "Plan ready — waiting for your approval to proceed"),
        ]),
        .init(id: "agentResp", label: "Agent responses", keyPath: \.agentResponse, entries: [
            .init(id: "cu-aar", rawEvent: "afterAgentResponse",
                  note: "Cursor replied to your prompt"),
        ]),
        .init(id: "sessionStart", label: "Session started", keyPath: \.sessionStart, entries: [
            .init(id: "cu-ss", rawEvent: "sessionStart", note: "New Cursor conversation started"),
        ]),
        .init(id: "subStart", label: "Sub-agent launched", keyPath: \.subagentStart, entries: [
            .init(id: "cu-sas", rawEvent: "subagentStart", note: "Background sub-agent started"),
        ]),
        .init(id: "subEnd", label: "Sub-agent finished", keyPath: \.subagentEnd, entries: [
            .init(id: "cu-sep", rawEvent: "subagentStop", note: "Sub-agent finished its task"),
        ]),
        .init(id: "toolUse", label: "Tool usage", keyPath: \.toolUse, entries: [
            .init(id: "cu-ptu",  rawEvent: "preToolUse",           note: "About to invoke a tool"),
            .init(id: "cu-postu", rawEvent: "postToolUse",          note: "Tool call completed"),
            .init(id: "cu-bsh",  rawEvent: "beforeShellExecution", note: "About to run a shell command"),
            .init(id: "cu-ash",  rawEvent: "afterShellExecution",  note: "Shell command completed"),
            .init(id: "cu-bmc",  rawEvent: "beforeMCPExecution",   note: "About to call an MCP tool"),
            .init(id: "cu-amc",  rawEvent: "afterMCPExecution",    note: "MCP tool call completed"),
        ]),
    ]

    // MARK: Windsurf Cascade
    // Windsurf has no dedicated sessionStart, error, or sub-agent hooks.
    // Both post_cascade_response variants map to sessionEnd — Windsurf may
    // send either, so both must be in this section for correct notifications.
    private static let windsurfSections: [AgentPhaseSection] = [
        .init(id: "sessionEnd", label: "Session completed", keyPath: \.sessionEnd, entries: [
            .init(id: "ws-pcr", rawEvent: "post_cascade_response",
                  note: "Cascade finished responding for this turn"),
            .init(id: "ws-pcrt", rawEvent: "post_cascade_response_with_transcript",
                  note: "Cascade replied (includes full conversation transcript)"),
        ]),
        .init(id: "perm", label: "Permission requests", keyPath: \.permissionNeeded, entries: [
            .init(id: "ws-pmcp", rawEvent: "pre_mcp_tool_use",
                  note: "MCP tool requires approval before execution"),
        ]),
        .init(id: "toolUse", label: "Tool usage", keyPath: \.toolUse, entries: [
            .init(id: "ws-prc",   rawEvent: "pre_read_code",    note: "About to read source code"),
            .init(id: "ws-porc",  rawEvent: "post_read_code",   note: "Code read complete"),
            .init(id: "ws-pwc",   rawEvent: "pre_write_code",   note: "About to write or edit code"),
            .init(id: "ws-powc",  rawEvent: "post_write_code",  note: "Code edit applied"),
            .init(id: "ws-prcmd", rawEvent: "pre_run_command",  note: "About to run a terminal command"),
            .init(id: "ws-porcmd", rawEvent: "post_run_command", note: "Command execution completed"),
            .init(id: "ws-pmcpr", rawEvent: "post_mcp_tool_use", note: "MCP tool call completed"),
        ]),
    ]

    // MARK: VS Code Copilot Chat
    // VSCode has no agentResponse hook.
    private static let vscodeSections: [AgentPhaseSection] = [
        .init(id: "sessionEnd", label: "Session completed", keyPath: \.sessionEnd, entries: [
            .init(id: "vs-se",   rawEvent: "SessionEnd", note: "Copilot Chat session ended"),
            .init(id: "vs-stop", rawEvent: "Stop",       note: "Extension agent stopped"),
        ]),
        .init(id: "error", label: "Errors", keyPath: \.error, entries: [
            .init(id: "vs-ptuf", rawEvent: "PostToolUseFailure",
                  note: "A VS Code or extension tool call failed"),
        ]),
        .init(id: "perm", label: "Permission requests", keyPath: \.permissionNeeded, entries: [
            .init(id: "vs-pr", rawEvent: "PermissionRequest",
                  note: "Extension requesting access to a resource"),
            .init(id: "vs-aq", rawEvent: "PreToolUse → vscode_askQuestions",
                  note: "Copilot asking you a question before continuing"),
            .init(id: "vs-sc", rawEvent: "PreToolUse → vscode_showConfirmation",
                  note: "Waiting for your confirmation to proceed"),
        ]),
        .init(id: "sessionStart", label: "Session started", keyPath: \.sessionStart, entries: [
            .init(id: "vs-ss", rawEvent: "SessionStart", note: "New Copilot Chat session began"),
        ]),
        .init(id: "subStart", label: "Sub-agent launched", keyPath: \.subagentStart, entries: [
            .init(id: "vs-sas", rawEvent: "SubagentStart", note: "Sub-agent task started"),
        ]),
        .init(id: "subEnd", label: "Sub-agent finished", keyPath: \.subagentEnd, entries: [
            .init(id: "vs-sep", rawEvent: "SubagentStop", note: "Sub-agent task finished"),
        ]),
        .init(id: "toolUse", label: "Tool usage", keyPath: \.toolUse, entries: [
            .init(id: "vs-ptu",  rawEvent: "PreToolUse",  note: "About to use a VS Code or extension tool"),
            .init(id: "vs-postu", rawEvent: "PostToolUse", note: "Tool call completed"),
        ]),
    ]

    // MARK: GitHub Copilot CLI
    // CopilotCLI has no permissionNeeded, agentResponse, or sub-agent hooks.
    private static let copilotCLISections: [AgentPhaseSection] = [
        .init(id: "sessionEnd", label: "Session completed", keyPath: \.sessionEnd, entries: [
            .init(id: "gh-se",       rawEvent: "sessionEnd",
                  note: "Session ended normally"),
            .init(id: "gh-errclean", rawEvent: "errorOccurred (Ctrl+C / user exit)",
                  note: "User quit — reclassified as a clean session end"),
        ]),
        .init(id: "error", label: "Errors", keyPath: \.error, entries: [
            .init(id: "gh-err", rawEvent: "errorOccurred (unexpected)",
                  note: "Unexpected runtime error (not a normal user-initiated exit)"),
        ]),
        .init(id: "sessionStart", label: "Session started", keyPath: \.sessionStart, entries: [
            .init(id: "gh-ss", rawEvent: "sessionStart", note: "gh copilot session started"),
        ]),
        .init(id: "toolUse", label: "Tool usage", keyPath: \.toolUse, entries: [
            .init(id: "gh-ptu",  rawEvent: "preToolUse",  note: "About to call a tool"),
            .init(id: "gh-postu", rawEvent: "postToolUse", note: "Tool call completed"),
        ]),
    ]

    // MARK: OpenAI Codex CLI
    // CodexCLI has no agentResponse or sub-agent hooks.
    private static let codexCLISections: [AgentPhaseSection] = [
        .init(id: "sessionEnd", label: "Session completed", keyPath: \.sessionEnd, entries: [
            .init(id: "cx-stop", rawEvent: "Stop", note: "Codex session ended"),
        ]),
        .init(id: "error", label: "Errors", keyPath: \.error, entries: [
            .init(id: "cx-err-e",   rawEvent: "Error",         note: "Generic error event"),
            .init(id: "cx-err-fe",  rawEvent: "fatal_error",   note: "Unrecoverable fatal error"),
            .init(id: "cx-err-re",  rawEvent: "runtime_error", note: "Runtime execution error"),
            .init(id: "cx-err-te",  rawEvent: "TypeError",     note: "Type mismatch error"),
            .init(id: "cx-err-se",  rawEvent: "SyntaxError",   note: "Invalid syntax error"),
            .init(id: "cx-err-ref", rawEvent: "ReferenceError",note: "Undefined reference error"),
            .init(id: "cx-err-cr",  rawEvent: "crash",         note: "Process crash"),
            .init(id: "cx-err-ab",  rawEvent: "abort",         note: "Abnormal process termination"),
        ]),
        .init(id: "perm", label: "Permission requests", keyPath: \.permissionNeeded, entries: [
            .init(id: "cx-pr",  rawEvent: "PermissionRequest",
                  note: "Codex requesting access before running a command"),
            .init(id: "cx-src", rawEvent: "PreToolUse → ShellCommandRequest",
                  note: "Shell command waiting for your approval"),
        ]),
        .init(id: "sessionStart", label: "Session started", keyPath: \.sessionStart, entries: [
            .init(id: "cx-ss", rawEvent: "SessionStart", note: "Codex session started or resumed"),
        ]),
        .init(id: "toolUse", label: "Tool usage", keyPath: \.toolUse, entries: [
            .init(id: "cx-ptu",  rawEvent: "PreToolUse",  note: "Codex about to run a tool or shell command"),
            .init(id: "cx-postu", rawEvent: "PostToolUse", note: "Tool execution completed"),
        ]),
    ]
}
