// AgentNotificationCatalog.swift — DoomCoder (Mac)
//
// Single source of truth for the *editable* notification surface shown in
// Configure → Agents. Supersedes the old read-only `AgentCapabilityCatalog`.
//
// For each agent it answers three questions:
//   1. Which notification categories can this agent actually emit?
//      (so we never show a toggle for something the agent's hooks can't produce)
//   2. For "Tool calls", what is the agent's tool palette (raw-ish name +
//      plain-language tooltip), so the user can allow/deny per tool?
//   3. For "Waiting for approval", what approval *kinds* exist, and which are
//      "noisy" (routine pre-exec gating like Cursor's beforeShellExecution)
//      so they can default OFF and stop notification spam?
//
// The same classifiers (`toolOptionID`, `approvalKindID`) are used by
// `AgentNotificationPrefs.shouldNotify` at dispatch time, so what the UI shows
// and what the gate enforces can never drift.

import Foundation

// MARK: - Category identity

/// User-facing notification categories. Each maps to one or more
/// `NormalizedEventPhase` values (see `AgentNotificationPrefs.shouldNotify`).
enum NotifCategoryID: String, CaseIterable, Codable, Sendable {
    case completed          // .sessionEnd
    case failed             // .error, .toolError
    case waitingApproval    // .permissionNeeded
    case waitingInput       // .agentResponse
    case sessionStart       // .sessionStart
    case toolCalls          // .toolStart, .toolEnd
    case subagentActivity   // .subagentStart, .subagentEnd
    // Opt-in coverage categories (all default OFF) — surface previously
    // dropped events. Map to the new NormalizedEventPhase coverage cases.
    case fileEdits          // .fileEdit
    case contextCompaction  // .compaction
    case agentThinking      // .thinking
    case housekeeping       // .housekeeping
    case userPromptSent     // .userPrompt
}

struct NotifCategoryMeta {
    let title: String
    let symbol: String
    let detail: String
    /// True for `toolCalls` — the editor shows a "when: started / finished / both" picker.
    let hasToolTrigger: Bool
}

/// One selectable tool in the "Tool calls" sub-list. `id` is the stable key
/// persisted in prefs and returned by `toolOptionID`; `label` is the raw-ish
/// name shown to the user; `tooltip` explains it in plain language.
struct ToolOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let tooltip: String
}

/// One approval kind in the "Waiting for approval" sub-list. `noisy` kinds
/// (routine pre-exec gating) default OFF so auto-approved actions don't spam.
struct ApprovalKind: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let tooltip: String
    let noisy: Bool
}

// MARK: - Catalog

enum AgentNotificationCatalog {

    // MARK: Category metadata

    static func meta(_ id: NotifCategoryID) -> NotifCategoryMeta {
        switch id {
        case .completed:
            return .init(title: "Task completed", symbol: "checkmark.circle.fill",
                         detail: "When an agent run finishes.", hasToolTrigger: false)
        case .failed:
            return .init(title: "Task failed", symbol: "exclamationmark.triangle.fill",
                         detail: "When a run errors out or is aborted.", hasToolTrigger: false)
        case .waitingApproval:
            return .init(title: "Waiting for approval", symbol: "hand.raised.fill",
                         detail: "When the agent needs you to approve something.", hasToolTrigger: false)
        case .waitingInput:
            return .init(title: "Waiting for your reply", symbol: "text.bubble.fill",
                         detail: "When the agent finished its turn and is waiting for your next message.", hasToolTrigger: false)
        case .sessionStart:
            return .init(title: "Session started", symbol: "play.circle.fill",
                         detail: "When a new agent session begins.", hasToolTrigger: false)
        case .toolCalls:
            return .init(title: "Tool calls", symbol: "wrench.and.screwdriver.fill",
                         detail: "When the agent runs tools — shell, edits, reads, and more.", hasToolTrigger: true)
        case .subagentActivity:
            return .init(title: "Sub-agent activity", symbol: "person.2.fill",
                         detail: "When the agent spawns or finishes a sub-agent.", hasToolTrigger: false)
        case .fileEdits:
            return .init(title: "File edits", symbol: "pencil.and.outline",
                         detail: "When the agent creates, edits, or changes a file.", hasToolTrigger: false)
        case .contextCompaction:
            return .init(title: "Context compaction", symbol: "rectangle.compress.vertical",
                         detail: "When the agent compacts the conversation to free up context.", hasToolTrigger: false)
        case .agentThinking:
            return .init(title: "Agent thinking", symbol: "brain",
                         detail: "When the agent records a reasoning step.", hasToolTrigger: false)
        case .housekeeping:
            return .init(title: "Workspace & housekeeping", symbol: "gearshape.2.fill",
                         detail: "Worktrees, config changes, instructions, and other background updates.", hasToolTrigger: false)
        case .userPromptSent:
            return .init(title: "Your prompts", symbol: "paperplane.fill",
                         detail: "When you submit a prompt to the agent.", hasToolTrigger: false)
        }
    }

    // MARK: Which categories each agent can emit
    //
    // Derived from each agent's normalizer phaseMap (AgentEventNormalizer.swift).
    // We only show toggles for categories the agent's hooks can actually produce.

    static func categories(for agent: TrackedAgent) -> [NotifCategoryID] {
        switch agent {
        case .claude:
            return [.completed, .failed, .waitingApproval, .waitingInput, .sessionStart, .toolCalls, .subagentActivity,
                    .fileEdits, .contextCompaction, .housekeeping, .userPromptSent]
        case .cursor:
            return [.completed, .failed, .waitingApproval, .waitingInput, .sessionStart, .toolCalls, .subagentActivity,
                    .fileEdits, .contextCompaction, .agentThinking, .housekeeping, .userPromptSent]
        case .vscode:
            return [.completed, .failed, .waitingApproval, .sessionStart, .toolCalls, .subagentActivity,
                    .contextCompaction, .userPromptSent]
        case .copilotCLI:
            return [.completed, .failed, .waitingApproval, .sessionStart, .toolCalls, .subagentActivity,
                    .contextCompaction, .userPromptSent]
        case .windsurf:
            // Windsurf emits no SessionStart, no error phase, no subagent events.
            return [.completed, .waitingApproval, .waitingInput, .toolCalls,
                    .housekeeping, .userPromptSent]
        case .codexCLI:
            // Codex has no distinct error or agentResponse phase, no subagents.
            return [.completed, .waitingApproval, .sessionStart, .toolCalls,
                    .contextCompaction, .userPromptSent]
        case .opencode:
            // opencode forwards: session.idle (completed), session.error (failed),
            // permission.v2.asked (approval), session.created (start),
            // tool.execute.before/after (tools), file.edited, session.compacted.
            // No subagent / user-prompt / agent-response events in the forwarded set.
            return [.completed, .failed, .waitingApproval, .sessionStart, .toolCalls,
                    .fileEdits, .contextCompaction]
        }
    }

    // MARK: Grouping (for the editor UI)
    //
    // Keeps the (now longer) category list scannable: a few high-signal
    // "Important" categories on top, routine "Activity" next, and rarely-wanted
    // "Housekeeping" last. Used by NotifyAboutCard to render section headers.

    enum CategoryGroup: String, CaseIterable {
        case important
        case activity
        case housekeeping

        var title: String {
            switch self {
            case .important:    return "Important"
            case .activity:     return "Activity"
            case .housekeeping: return "Housekeeping"
            }
        }
    }

    static func group(_ id: NotifCategoryID) -> CategoryGroup {
        switch id {
        case .completed, .failed, .waitingApproval, .waitingInput:
            return .important
        case .sessionStart, .toolCalls, .subagentActivity, .fileEdits,
             .agentThinking, .userPromptSent:
            return .activity
        case .contextCompaction, .housekeeping:
            return .housekeeping
        }
    }

    /// Categories the agent can emit, bucketed into display groups (ordered),
    /// skipping empty groups.
    static func groupedCategories(for agent: TrackedAgent) -> [(CategoryGroup, [NotifCategoryID])] {
        let all = categories(for: agent)
        return CategoryGroup.allCases.compactMap { g in
            let items = all.filter { group($0) == g }
            return items.isEmpty ? nil : (g, items)
        }
    }

    // MARK: Tool palette per agent (raw-ish name + plain-language tooltip)

    static func tools(for agent: TrackedAgent) -> [ToolOption] {
        let shell  = ToolOption(id: "shell",  label: "Run commands",  tooltip: "Runs shell / terminal commands")
        let edit   = ToolOption(id: "edit",   label: "Edit files",    tooltip: "Creates, edits, or deletes files")
        let read   = ToolOption(id: "read",   label: "Read files",    tooltip: "Reads files from your project")
        let search = ToolOption(id: "search", label: "Search code",   tooltip: "Searches your codebase (grep / glob)")
        let web    = ToolOption(id: "web",    label: "Web access",    tooltip: "Fetches a URL or searches the web")
        let task   = ToolOption(id: "task",   label: "Sub-agents",    tooltip: "Launches a sub-agent to do work")
        let todo   = ToolOption(id: "todo",   label: "Task list",     tooltip: "Updates its to-do / task list")
        let mcp    = ToolOption(id: "mcp",    label: "MCP tools",     tooltip: "Calls tools from an MCP server")
        let other  = ToolOption(id: "other",  label: "Anything else", tooltip: "Any other tool not listed above")

        switch agent {
        case .claude:
            return [shell, edit, read, search, web, task, todo, mcp, other]
        case .cursor:
            return [shell, edit, read, mcp, other]
        case .vscode, .copilotCLI, .codexCLI:
            return [shell, edit, read, search, mcp, other]
        case .windsurf:
            return [shell, edit, read, mcp, other]
        case .opencode:
            // opencode's built-in tools: bash, edit/write, read, grep/glob,
            // webfetch — no first-class MCP tool naming in the forwarded payload.
            return [shell, edit, read, search, web, other]
        }
    }

    /// Classifies an observed raw tool name into a stable `ToolOption.id`.
    /// Used by both the editor's "X selected" summary and the dispatch gate,
    /// so display and enforcement stay in lock-step. Order = specific → generic.
    static func toolOptionID(forToolName name: String) -> String {
        if name.hasPrefix("mcp__") || name.hasPrefix("MCP:") { return "mcp" }
        let n = name.lowercased()
        if n.contains("mcp") { return "mcp" }
        if n.contains("todo") { return "todo" }
        if n.contains("web") || n.contains("fetch") || n.contains("url") || n.contains("browser") { return "web" }
        if n.contains("glob") || n.contains("grep") || n.contains("search") || n.contains("find") { return "search" }
        if n == "task" || n.contains("subagent") || n.contains("sub_agent") || n.contains("agent") { return "task" }
        if n == "bash" || n == "shell" || n.contains("terminal") || n.contains("command")
            || n.contains("run") || n.contains("exec") { return "shell" }
        if n.contains("edit") || n.contains("write") || n.contains("create")
            || n.contains("apply") || n.contains("patch") || n.contains("delete")
            || n.contains("notebook") { return "edit" }
        if n.contains("read") || n.contains("view") || n.contains("cat") || n.contains("open") { return "read" }
        return "other"
    }

    // MARK: Approval kinds per agent

    static func approvalKinds(for agent: TrackedAgent) -> [ApprovalKind] {
        switch agent {
        case .claude:
            return [ApprovalKind(id: "prompt", title: "Permission prompts & plan approvals",
                                 tooltip: "When Claude asks you to approve a tool or a plan.", noisy: false)]
        case .cursor:
            return [
                ApprovalKind(id: "shell", title: "Shell commands",
                             tooltip: "When Cursor needs approval to run a command. DoomCoder waits briefly and stays silent if Cursor auto-approves it.", noisy: false),
                ApprovalKind(id: "mcp", title: "MCP tools",
                             tooltip: "When Cursor needs approval to run an MCP tool. Auto-approved calls are filtered out automatically.", noisy: false),
            ]
        case .copilotCLI:
            return [
                ApprovalKind(id: "prompt", title: "Permission prompts",
                             tooltip: "When Copilot asks permission to run something. Auto-approved requests (per your Copilot allow-list) are filtered out automatically.", noisy: false),
                ApprovalKind(id: "question", title: "Questions & plan approvals",
                             tooltip: "When Copilot asks you a question or to approve a plan.", noisy: false),
            ]
        case .vscode:
            return [ApprovalKind(id: "prompt", title: "Permission prompts",
                                 tooltip: "When Copilot asks you to confirm a tool.", noisy: false)]
        case .codexCLI:
            return [ApprovalKind(id: "prompt", title: "Permission prompts",
                                 tooltip: "When Codex asks you to approve a command.", noisy: false)]
        case .windsurf:
            return [ApprovalKind(id: "mcp", title: "MCP tools",
                                 tooltip: "When Windsurf needs approval to run an MCP tool. Auto-approved calls are filtered out automatically.", noisy: false)]
        case .opencode:
            return [ApprovalKind(id: "prompt", title: "Permission prompts",
                                 tooltip: "When opencode asks you to approve a tool or command.", noisy: false)]
        }
    }

    /// Classifies a `.permissionNeeded` event into an approval-kind id for the
    /// agent. Mirrors the per-agent logic in AgentEventNormalizer.swift.
    static func approvalKindID(for agent: TrackedAgent, rawEvent: String, toolName: String?) -> String {
        switch agent {
        case .cursor:
            if rawEvent == "beforeMCPExecution" { return "mcp" }
            return "shell"   // beforeShellExecution and anything else
        case .copilotCLI:
            if let t = toolName, ["ask_user", "exit_plan_mode"].contains(t) { return "question" }
            return "prompt"
        case .windsurf:
            return "mcp"
        case .claude, .vscode, .codexCLI, .opencode:
            return "prompt"
        }
    }
}
