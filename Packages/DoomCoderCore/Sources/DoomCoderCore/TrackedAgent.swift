import Foundation

/// Shared TrackedAgent enum (mirror of the Mac-side enum in
/// DoomCoder/AgentTracking/HookEnvelope.swift). Both definitions must stay in
/// lock-step; the CloudKit `agent` field is the raw String value.
public enum TrackedAgent: String, CaseIterable, Sendable, Codable {
    case claude
    case cursor
    case vscode
    case copilotCLI = "copilot_cli"
    case windsurf
    case codexCLI = "codex_cli"

    public var displayName: String {
        switch self {
        case .claude:     return "Claude Code"
        case .cursor:     return "Cursor"
        case .vscode:     return "VS Code Copilot"
        case .copilotCLI: return "Copilot CLI"
        case .windsurf:   return "Windsurf"
        case .codexCLI:   return "Codex CLI"
        }
    }

    public var isIDEAgent: Bool {
        switch self {
        case .cursor, .vscode, .windsurf: return true
        case .claude, .copilotCLI, .codexCLI: return false
        }
    }

    /// Stable lobehub-style icon slug used by both Mac (CDN download) and iOS
    /// (read from AgentIcon CloudKit asset cache).
    public var iconSlug: String {
        switch self {
        case .claude:     return "claude"
        case .cursor:     return "cursor"
        case .vscode:     return "vscode"
        case .copilotCLI: return "github-copilot"
        case .windsurf:   return "windsurf"
        case .codexCLI:   return "openai"
        }
    }
}
