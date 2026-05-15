import Foundation

// MARK: - Data types

/// One hook event shown in the per-agent notification preferences UI.
struct AgentEventEntry: Identifiable, Sendable {
    /// Stable id for ForEach (unique within the parent section).
    let id: String
    /// Raw event name exactly as emitted by the hook (e.g. "SessionEnd", "stop").
    /// This is the key used in NotificationPrefs.enabledEvents.
    let rawEvent: String
    /// Short description of when this event fires for this agent.
    let note: String
}

/// A display-only grouping of related hook events in the notification prefs UI.
/// Sections are for readability only — each entry has its own independent toggle.
struct AgentPhaseSection: Identifiable, Sendable {
    let id: String
    let label: String
    let entries: [AgentEventEntry]
}

// MARK: - Catalog

/// Per-agent notification event catalog.
///
/// Lists only events that are actually installed for each agent
/// (matching AgentInstallerV2's event lists). Sections are display-only
/// groupings — each entry drives its own independent notification toggle
/// via NotificationPrefs.enabledEvents[rawEvent].
enum AgentEventCatalog {

    /// Non-empty sections for `agent`, in display order.
    static func sections(for agent: TrackedAgent) -> [AgentPhaseSection] {
        allSections(for: agent).filter { !$0.entries.isEmpty }
    }

    /// Flat list of all entries for `agent` — useful for building per-event defaults.
    static func allEntries(for agent: TrackedAgent) -> [AgentEventEntry] {
        allSections(for: agent).flatMap { $0.entries }
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
    // All events match AgentInstallerV2.claudeEvents.
    private static let claudeSections: [AgentPhaseSection] = [
        .init(id: "session", label: "Session", entries: [
            .init(id: "cl-ss",   rawEvent: "SessionStart",  note: "New Claude Code session began"),
            .init(id: "cl-se",   rawEvent: "SessionEnd",    note: "Session finished normally"),
            .init(id: "cl-stop", rawEvent: "Stop",          note: "Agent stopped cleanly"),
            .init(id: "cl-sf",   rawEvent: "StopFailure",   note: "Fatal crash — session could not recover"),
        ]),
        .init(id: "tasks", label: "Tasks", entries: [
            .init(id: "cl-tcr", rawEvent: "TaskCreated",   note: "Background sub-task created"),
            .init(id: "cl-tc",  rawEvent: "TaskCompleted", note: "Background sub-task finished"),
        ]),
        .init(id: "notification", label: "Notifications", entries: [
            .init(id: "cl-notif", rawEvent: "Notification",
                  note: "Claude sent a message, status update, or permission request"),
        ]),
        .init(id: "prompt", label: "User prompts", entries: [
            .init(id: "cl-ups", rawEvent: "UserPromptSubmit",    note: "You submitted a message"),
            .init(id: "cl-upe", rawEvent: "UserPromptExpansion", note: "Prompt was expanded with context"),
        ]),
        .init(id: "tools", label: "Tool use", entries: [
            .init(id: "cl-ptu",   rawEvent: "PreToolUse",         note: "About to invoke a tool (Bash, Edit, Read…)"),
            .init(id: "cl-postu", rawEvent: "PostToolUse",        note: "Tool call completed"),
            .init(id: "cl-ptuf",  rawEvent: "PostToolUseFailure", note: "Tool execution returned an error"),
            .init(id: "cl-ptb",   rawEvent: "PostToolBatch",      note: "Batch of tool calls completed"),
        ]),
        .init(id: "perm", label: "Permissions", entries: [
            .init(id: "cl-pr",  rawEvent: "PermissionRequest", note: "Claude requesting access to a resource"),
            .init(id: "cl-pd",  rawEvent: "PermissionDenied",  note: "Permission denied — may need intervention"),
            .init(id: "cl-el",  rawEvent: "Elicitation",       note: "Claude paused, waiting for clarification"),
            .init(id: "cl-elr", rawEvent: "ElicitationResult", note: "Clarification was submitted"),
        ]),
        .init(id: "subagent", label: "Sub-agents", entries: [
            .init(id: "cl-sas", rawEvent: "SubagentStart",  note: "Background sub-agent launched"),
            .init(id: "cl-sep", rawEvent: "SubagentStop",   note: "Sub-agent finished its task"),
            .init(id: "cl-ti",  rawEvent: "TeammateIdle",   note: "Teammate agent is idle"),
        ]),
        .init(id: "context", label: "Context & config", entries: [
            .init(id: "cl-pc",   rawEvent: "PreCompact",         note: "Before context is compacted"),
            .init(id: "cl-poc",  rawEvent: "PostCompact",        note: "Context was compacted"),
            .init(id: "cl-il",   rawEvent: "InstructionsLoaded", note: "Agent instructions loaded"),
            .init(id: "cl-cc",   rawEvent: "ConfigChange",       note: "Configuration changed"),
            .init(id: "cl-fc",   rawEvent: "FileChanged",        note: "A file changed on disk"),
            .init(id: "cl-cwdc", rawEvent: "CwdChanged",         note: "Working directory changed"),
        ]),
        .init(id: "setup", label: "Setup", entries: [
            .init(id: "cl-setup", rawEvent: "Setup",          note: "Agent environment initialized"),
            .init(id: "cl-wc",    rawEvent: "WorktreeCreate", note: "Git worktree created"),
            .init(id: "cl-wr",    rawEvent: "WorktreeRemove", note: "Git worktree removed"),
        ]),
    ]

    // MARK: Cursor
    // All events match AgentInstallerV2.cursorEvents.
    private static let cursorSections: [AgentPhaseSection] = [
        .init(id: "session", label: "Session", entries: [
            .init(id: "cu-ss",   rawEvent: "sessionStart", note: "New Cursor agent session started"),
            .init(id: "cu-se",   rawEvent: "sessionEnd",   note: "Conversation session ended"),
            .init(id: "cu-stop", rawEvent: "stop",         note: "Agent stopped cleanly"),
        ]),
        .init(id: "response", label: "Responses", entries: [
            .init(id: "cu-aar", rawEvent: "afterAgentResponse",
                  note: "Cursor finished replying to your prompt"),
            .init(id: "cu-aat", rawEvent: "afterAgentThought",
                  note: "Cursor finished an internal reasoning step"),
        ]),
        .init(id: "prompt", label: "Prompts", entries: [
            .init(id: "cu-bsp", rawEvent: "beforeSubmitPrompt",
                  note: "Your message is about to be submitted"),
        ]),
        .init(id: "tools", label: "Tool use", entries: [
            .init(id: "cu-ptu",   rawEvent: "preToolUse",          note: "About to invoke a tool"),
            .init(id: "cu-postu", rawEvent: "postToolUse",         note: "Tool call completed"),
            .init(id: "cu-ptuf",  rawEvent: "postToolUseFailure",  note: "Tool execution returned an error"),
            .init(id: "cu-bsh",   rawEvent: "beforeShellExecution",note: "About to run a shell command"),
            .init(id: "cu-ash",   rawEvent: "afterShellExecution", note: "Shell command completed"),
            .init(id: "cu-bmc",   rawEvent: "beforeMCPExecution",  note: "About to call an MCP tool"),
            .init(id: "cu-amc",   rawEvent: "afterMCPExecution",   note: "MCP tool call completed"),
        ]),
        .init(id: "files", label: "File operations", entries: [
            .init(id: "cu-afe", rawEvent: "afterFileEdit",  note: "A file was edited"),
            .init(id: "cu-brf", rawEvent: "beforeReadFile", note: "About to read a file"),
        ]),
        .init(id: "subagent", label: "Sub-agents", entries: [
            .init(id: "cu-sas", rawEvent: "subagentStart", note: "Background sub-agent started"),
            .init(id: "cu-sep", rawEvent: "subagentStop",  note: "Sub-agent finished its task"),
        ]),
        .init(id: "other", label: "Other", entries: [
            .init(id: "cu-pc",   rawEvent: "preCompact",       note: "Before context is compacted"),
            .init(id: "cu-btfr", rawEvent: "beforeTabFileRead", note: "Tab completion is about to read a file"),
            .init(id: "cu-atfe", rawEvent: "afterTabFileEdit",  note: "Tab completion edited a file"),
        ]),
    ]

    // MARK: Windsurf Cascade
    // All events match AgentInstallerV2.windsurfEvents.
    // Both post_cascade_response variants are listed — Windsurf may send either
    // depending on version, so users can enable both to ensure notifications fire.
    private static let windsurfSections: [AgentPhaseSection] = [
        .init(id: "response", label: "Responses", entries: [
            .init(id: "ws-pcr",  rawEvent: "post_cascade_response",
                  note: "Cascade finished responding for this turn"),
            .init(id: "ws-pcrt", rawEvent: "post_cascade_response_with_transcript",
                  note: "Cascade replied (includes full conversation transcript)"),
        ]),
        .init(id: "perm", label: "Permissions", entries: [
            .init(id: "ws-pmcp", rawEvent: "pre_mcp_tool_use",
                  note: "MCP tool requires approval before execution"),
        ]),
        .init(id: "prompt", label: "User prompts", entries: [
            .init(id: "ws-pup", rawEvent: "pre_user_prompt",
                  note: "User is about to submit a message"),
        ]),
        .init(id: "tools", label: "Tool use", entries: [
            .init(id: "ws-prc",    rawEvent: "pre_read_code",     note: "About to read source code"),
            .init(id: "ws-porc",   rawEvent: "post_read_code",    note: "Code read complete"),
            .init(id: "ws-pwc",    rawEvent: "pre_write_code",    note: "About to write or edit code"),
            .init(id: "ws-powc",   rawEvent: "post_write_code",   note: "Code edit applied"),
            .init(id: "ws-prcmd",  rawEvent: "pre_run_command",   note: "About to run a terminal command"),
            .init(id: "ws-porcmd", rawEvent: "post_run_command",  note: "Command execution completed"),
            .init(id: "ws-pmcpr",  rawEvent: "post_mcp_tool_use", note: "MCP tool call completed"),
        ]),
        .init(id: "other", label: "Other", entries: [
            .init(id: "ws-psw", rawEvent: "post_setup_worktree",
                  note: "Worktree environment was set up"),
        ]),
    ]

    // MARK: VS Code Copilot Chat
    // All 29 events mirror AgentInstallerV2.vscodeEvents (identical to Claude Code).
    // VS Code currently fires 8 events natively (SessionStart, UserPromptSubmit,
    // PreToolUse, PostToolUse, PreCompact, SubagentStart, SubagentStop, Stop).
    // The remaining events are registered so DoomCoder automatically captures them
    // as VS Code expands its hook support (the feature is still in Preview).
    private static let vscodeSections: [AgentPhaseSection] = [
        .init(id: "session", label: "Session", entries: [
            .init(id: "vs-ss",    rawEvent: "SessionStart",  note: "New VS Code Copilot session began"),
            .init(id: "vs-setup", rawEvent: "Setup",         note: "Agent environment initialized"),
            .init(id: "vs-se",    rawEvent: "SessionEnd",    note: "Session finished normally"),
            .init(id: "vs-stop",  rawEvent: "Stop",          note: "Agent stopped — session ended"),
            .init(id: "vs-sf",    rawEvent: "StopFailure",   note: "Fatal crash — session could not recover"),
        ]),
        .init(id: "tasks", label: "Tasks", entries: [
            .init(id: "vs-tcr", rawEvent: "TaskCreated",   note: "Background sub-task created"),
            .init(id: "vs-tc",  rawEvent: "TaskCompleted", note: "Background sub-task finished"),
        ]),
        .init(id: "notification", label: "Notifications", entries: [
            .init(id: "vs-notif", rawEvent: "Notification",
                  note: "Copilot sent a message, status update, or alert"),
        ]),
        .init(id: "prompt", label: "User prompts", entries: [
            .init(id: "vs-ups", rawEvent: "UserPromptSubmit",    note: "You submitted a message"),
            .init(id: "vs-upe", rawEvent: "UserPromptExpansion", note: "Prompt was expanded with context"),
        ]),
        .init(id: "tools", label: "Tool use", entries: [
            .init(id: "vs-ptu",   rawEvent: "PreToolUse",         note: "About to invoke a tool (Bash, Edit, Read…)"),
            .init(id: "vs-postu", rawEvent: "PostToolUse",        note: "Tool call completed"),
            .init(id: "vs-ptuf",  rawEvent: "PostToolUseFailure", note: "Tool execution returned an error"),
            .init(id: "vs-ptb",   rawEvent: "PostToolBatch",      note: "Batch of tool calls completed"),
        ]),
        .init(id: "perm", label: "Permissions", entries: [
            .init(id: "vs-pr",  rawEvent: "PermissionRequest", note: "Copilot requesting access to a resource"),
            .init(id: "vs-pd",  rawEvent: "PermissionDenied",  note: "Permission denied — may need intervention"),
            .init(id: "vs-el",  rawEvent: "Elicitation",       note: "Copilot paused, waiting for clarification"),
            .init(id: "vs-elr", rawEvent: "ElicitationResult", note: "Clarification was submitted"),
        ]),
        .init(id: "subagent", label: "Sub-agents", entries: [
            .init(id: "vs-sas", rawEvent: "SubagentStart", note: "Sub-agent task started"),
            .init(id: "vs-sep", rawEvent: "SubagentStop",  note: "Sub-agent task finished"),
            .init(id: "vs-ti",  rawEvent: "TeammateIdle",  note: "Teammate agent is idle"),
        ]),
        .init(id: "context", label: "Context & config", entries: [
            .init(id: "vs-pc",   rawEvent: "PreCompact",         note: "Before context is compacted"),
            .init(id: "vs-poc",  rawEvent: "PostCompact",        note: "Context was compacted"),
            .init(id: "vs-il",   rawEvent: "InstructionsLoaded", note: "Agent instructions loaded"),
            .init(id: "vs-cc",   rawEvent: "ConfigChange",       note: "Configuration changed"),
            .init(id: "vs-fc",   rawEvent: "FileChanged",        note: "A file changed on disk"),
            .init(id: "vs-cwdc", rawEvent: "CwdChanged",         note: "Working directory changed"),
        ]),
        .init(id: "setup", label: "Setup", entries: [
            .init(id: "vs-wc", rawEvent: "WorktreeCreate", note: "Git worktree created"),
            .init(id: "vs-wr", rawEvent: "WorktreeRemove", note: "Git worktree removed"),
        ]),
    ]

    // MARK: GitHub Copilot CLI
    // All events match AgentInstallerV2.copilotCLIEvents.
    // errorOccurred covers both real errors and clean user-exits; the tracker
    // reclassifies clean exits to sessionEnd internally for session state,
    // but the raw event name is always errorOccurred.
    private static let copilotCLISections: [AgentPhaseSection] = [
        .init(id: "session", label: "Session", entries: [
            .init(id: "gh-ss", rawEvent: "sessionStart", note: "gh copilot session started"),
            .init(id: "gh-se", rawEvent: "sessionEnd",   note: "Session ended normally"),
        ]),
        .init(id: "errors", label: "Errors & exits", entries: [
            .init(id: "gh-err", rawEvent: "errorOccurred",
                  note: "Error or unexpected exit (Ctrl+C / user quit is automatically reclassified as a clean end)"),
        ]),
        .init(id: "prompt", label: "Prompts", entries: [
            .init(id: "gh-ups", rawEvent: "userPromptSubmitted", note: "You submitted a message"),
        ]),
        .init(id: "tools", label: "Tool use", entries: [
            .init(id: "gh-ptu",   rawEvent: "preToolUse",  note: "About to call a tool"),
            .init(id: "gh-postu", rawEvent: "postToolUse", note: "Tool call completed"),
        ]),
    ]

    // MARK: OpenAI Codex CLI
    // Events match AgentInstallerV2.codexEvents (SessionStart, PreToolUse,
    // PermissionRequest, PostToolUse, UserPromptSubmit, Stop).
    private static let codexCLISections: [AgentPhaseSection] = [
        .init(id: "session", label: "Session", entries: [
            .init(id: "cx-ss",   rawEvent: "SessionStart", note: "Codex session started or resumed"),
            .init(id: "cx-stop", rawEvent: "Stop",         note: "Codex session ended"),
        ]),
        .init(id: "perm", label: "Permissions", entries: [
            .init(id: "cx-pr", rawEvent: "PermissionRequest",
                  note: "Codex requesting approval before running a command"),
        ]),
        .init(id: "prompt", label: "Prompts", entries: [
            .init(id: "cx-ups", rawEvent: "UserPromptSubmit", note: "You submitted a message"),
        ]),
        .init(id: "tools", label: "Tool use", entries: [
            .init(id: "cx-ptu",   rawEvent: "PreToolUse",  note: "About to run a tool or shell command"),
            .init(id: "cx-postu", rawEvent: "PostToolUse", note: "Tool execution completed"),
        ]),
    ]
}
