import Foundation

// MARK: - AgentSession
//
// Live state for one AI-agent session. Owned exclusively by AgentStatusManager on
// @MainActor — this struct is just a value-type snapshot we mutate in place.

struct AgentSession: Identifiable, Equatable, Sendable {

    enum State: String, Sendable {
        case active       // fresh start or info/progress events
        case waiting      // agent blocked on user input
        case errored      // agent hit an error but session still running
        case done         // session closed cleanly or timed out
    }

    let id: String               // sessionKey from the first event (stable across updates)
    let agent: String
    let startedAt: Date

    var state: State
    var lastEventAt: Date
    var cwd: String?
    var currentTool: String?
    var toolCount: Int
    var lastMessage: String?
    var source: AgentEvent.Source

    // A human-readable "Claude Code" / "Copilot CLI" / "Cursor" — we resolve a known
    // mapping per agent id, and fall back to title-casing the id for unknown agents.
    var displayName: String { AgentCatalog.displayName(forId: agent) }

    // Shorthand repository name (last path component of cwd), shown in Live Activity.
    var repoName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let url = URL(fileURLWithPath: cwd)
        return url.lastPathComponent
    }

    var elapsed: TimeInterval { Date.now.timeIntervalSince(startedAt) }

    var elapsedText: String {
        let total = Int(elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

// MARK: - AgentCatalog
//
// Central place to resolve agent ids to a display name and their installation tier.
// Adding a new agent only requires one entry here plus an entry in HookInstaller or
// MCPInstaller.

enum AgentCatalog {

    struct Info: Sendable {
        let id: String
        let displayName: String
        let tier: Tier

        enum Tier: Sendable { case hook, mcp }
    }

    static let all: [Info] = [
        Info(id: "claude-code", displayName: "Claude Code",  tier: .hook),
        Info(id: "copilot-cli", displayName: "Copilot CLI",  tier: .hook),
        Info(id: "cursor",      displayName: "Cursor",       tier: .mcp),
        Info(id: "windsurf",    displayName: "Windsurf",     tier: .mcp),
        Info(id: "gemini-cli",  displayName: "Gemini CLI",   tier: .mcp),
        Info(id: "codex",       displayName: "Codex",        tier: .mcp),
        Info(id: "aider",       displayName: "Aider",        tier: .mcp),
        Info(id: "vscode-mcp",  displayName: "VS Code (MCP)", tier: .mcp),
    ]

    static func info(forId id: String) -> Info? {
        all.first { $0.id == id }
    }

    static func displayName(forId id: String) -> String {
        if let info = info(forId: id) { return info.displayName }
        // Fall back: "some-agent" → "Some Agent"
        return id.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
