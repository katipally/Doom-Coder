import Foundation

// MARK: - MCPInstaller
//
// Writes DoomCoder's MCP server entry into each supported agent's MCP
// configuration file. Every mutation follows the same contract Phase A's
// HookInstaller established:
//
//   1. Always back up the existing file (timestamped, kept forever).
//   2. Merge rather than overwrite — never clobber the user's other MCP
//      servers.
//   3. Tag our entry with a `doomcoder-managed` sentinel so re-runs are
//      idempotent and uninstall can precisely remove what we added.
//   4. Offer a matching Restore Backup button in Settings that rolls any
//      installer back to the most recent pre-install state.
//
// Supported agents in Phase B:
//   • Cursor       — ~/.cursor/mcp.json (JSON)
//   • Windsurf     — ~/.codeium/windsurf/mcp_config.json (JSON)
//   • VS Code      — ~/Library/Application Support/Code/User/mcp.json (JSON)
//   • Gemini CLI   — ~/.gemini/settings.json (JSON)
//   • Codex CLI    — ~/.codex/config.toml (TOML; string-level edit)

enum MCPInstaller {

    enum Agent: String, CaseIterable, Identifiable {
        case cursor, windsurf, vscode, gemini, codex
        var id: String { rawValue }

        var catalogId: String {
            switch self {
            case .cursor:   return "cursor"
            case .windsurf: return "windsurf"
            case .vscode:   return "vscode-mcp"
            case .gemini:   return "gemini-cli"
            case .codex:    return "codex"
            }
        }

        var displayName: String {
            AgentCatalog.displayName(forId: catalogId)
        }

        /// One-liner shown on the card explaining what we'll change.
        var summary: String {
            switch self {
            case .cursor:
                return "Adds a \"doomcoder\" entry to ~/.cursor/mcp.json. Cursor will spawn this MCP server automatically the next time it starts."
            case .windsurf:
                return "Adds a \"doomcoder\" entry to ~/.codeium/windsurf/mcp_config.json. Windsurf/Cascade spawns the server on its next launch."
            case .vscode:
                return "Adds a \"doomcoder\" entry to VS Code's user-wide mcp.json. Works with GitHub Copilot's agent mode and any MCP-aware extension."
            case .gemini:
                return "Adds a \"doomcoder\" MCP server to ~/.gemini/settings.json. Gemini CLI will connect on its next run."
            case .codex:
                return "Appends an [mcp_servers.doomcoder] section to ~/.codex/config.toml. Codex CLI will pick it up on the next command."
            }
        }

        /// Path to the agent's MCP config file in the user's home.
        var configPath: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .cursor:
                return home.appendingPathComponent(".cursor/mcp.json")
            case .windsurf:
                return home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
            case .vscode:
                return home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
            case .gemini:
                return home.appendingPathComponent(".gemini/settings.json")
            case .codex:
                return home.appendingPathComponent(".codex/config.toml")
            }
        }

        /// Where we park timestamped backups before every mutation.
        var backupDir: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".doomcoder/backups/\(rawValue)", isDirectory: true)
        }

        var isTOML: Bool { self == .codex }

        /// Human-readable key that identifies "our" server entry inside the
        /// config. Same across all agents for easy grep + uninstall.
        static let serverKey = "doomcoder"
    }

    enum Status: String { case installed, notInstalled, modified, missingConfig }

    enum InstallError: Error {
        case writeFailed(URL, underlying: Error)
        case malformedConfig(URL)
    }

    // MARK: - Status

    static func status(for agent: Agent) -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: agent.configPath.path) else {
            return .notInstalled
        }
        guard let data = try? Data(contentsOf: agent.configPath) else {
            return .missingConfig
        }
        if agent.isTOML {
            guard let text = String(data: data, encoding: .utf8) else { return .missingConfig }
            return text.contains(tomlSectionHeader) ? .installed : .notInstalled
        }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let servers = obj["mcpServers"] as? [String: Any],
            let entry = servers[Agent.serverKey] as? [String: Any]
        else {
            return .notInstalled
        }
        // We only report "installed" if our sentinel is present — otherwise a
        // user- or tool-authored "doomcoder" entry could make us think we're
        // already set up when we aren't.
        return (entry["doomcoder-managed"] as? Bool == true) ? .installed : .modified
    }

    // MARK: - Install

    @discardableResult
    static func install(_ agent: Agent) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: agent.configPath.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        let backupURL = try backup(agent)

        if agent.isTOML {
            try writeTOML(for: agent)
        } else {
            try writeJSON(for: agent)
        }
        return backupURL
    }

    /// Removes every trace of DoomCoder from the agent's config, leaving the
    /// user's other servers untouched.
    @discardableResult
    static func uninstall(_ agent: Agent) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: agent.configPath.path) else { return nil }

        let backupURL = try backup(agent)

        if agent.isTOML {
            try stripTOMLSection(at: agent.configPath)
        } else {
            try stripJSONEntry(at: agent.configPath)
        }
        return backupURL
    }

    // MARK: - Backup / Restore

    @discardableResult
    static func backup(_ agent: Agent) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: agent.configPath.path) else { return nil }
        try fm.createDirectory(at: agent.backupDir, withIntermediateDirectories: true)
        let ts = Int(Date().timeIntervalSince1970)
        let suffix = agent.isTOML ? "toml" : "json"
        let dest = agent.backupDir.appendingPathComponent("\(ts).\(suffix)")
        try fm.copyItem(at: agent.configPath, to: dest)
        return dest
    }

    @discardableResult
    static func restoreLatestBackup(_ agent: Agent) throws -> URL? {
        let fm = FileManager.default
        guard let latest = try latestBackup(for: agent) else { return nil }
        if fm.fileExists(atPath: agent.configPath.path) {
            try fm.removeItem(at: agent.configPath)
        }
        try fm.createDirectory(at: agent.configPath.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.copyItem(at: latest, to: agent.configPath)
        return latest
    }

    static func latestBackup(for agent: Agent) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: agent.backupDir.path) else { return nil }
        let items = try fm.contentsOfDirectory(at: agent.backupDir,
                                               includingPropertiesForKeys: [.contentModificationDateKey])
        return items.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    // MARK: - JSON merge

    private static func writeJSON(for agent: Agent) throws {
        let fm = FileManager.default
        var root: [String: Any] = [:]

        if fm.fileExists(atPath: agent.configPath.path),
           let data = try? Data(contentsOf: agent.configPath),
           !data.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.malformedConfig(agent.configPath)
            }
            root = obj
        }

        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        let invocation = MCPRuntime.invocation
        servers[Agent.serverKey] = [
            "command": invocation.command,
            "args":    invocation.args,
            "doomcoder-managed": true
        ] as [String: Any]
        root["mcpServers"] = servers

        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys])
        do {
            try out.write(to: agent.configPath, options: .atomic)
        } catch {
            throw InstallError.writeFailed(agent.configPath, underlying: error)
        }
    }

    private static func stripJSONEntry(at url: URL) throws {
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.malformedConfig(url)
        }
        if var servers = root["mcpServers"] as? [String: Any] {
            servers.removeValue(forKey: Agent.serverKey)
            if servers.isEmpty {
                root.removeValue(forKey: "mcpServers")
            } else {
                root["mcpServers"] = servers
            }
        }

        if root.isEmpty {
            try FileManager.default.removeItem(at: url)
            return
        }
        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    // MARK: - TOML (Codex)

    /// Section header we write + search for. Codex lets us have multiple
    /// `[mcp_servers.NAME]` sections — we own exactly this one.
    private static let tomlSectionHeader = "[mcp_servers.doomcoder]"
    private static let tomlManagedMarker = "# doomcoder-managed"

    private static func writeTOML(for agent: Agent) throws {
        let fm = FileManager.default
        var existing: String = ""
        if fm.fileExists(atPath: agent.configPath.path),
           let text = try? String(contentsOf: agent.configPath, encoding: .utf8) {
            existing = text
        }

        let stripped = removeDoomcoderSection(from: existing)

        let invocation = MCPRuntime.invocation
        let argsLiteral = invocation.args
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            .joined(separator: ", ")

        let block = """

        \(tomlManagedMarker)
        \(tomlSectionHeader)
        command = "\(invocation.command)"
        args = [\(argsLiteral)]
        """

        let out = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            + (stripped.isEmpty ? "" : "\n") + block + "\n"
        try out.write(to: agent.configPath, atomically: true, encoding: .utf8)
    }

    private static func stripTOMLSection(at url: URL) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let cleaned = removeDoomcoderSection(from: text)
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try FileManager.default.removeItem(at: url)
        } else {
            try cleaned.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Removes our `[mcp_servers.doomcoder]` block (plus optional preceding
    /// `# doomcoder-managed` marker) while leaving every other section in the
    /// file untouched. We stop at the first blank line or the start of the
    /// next `[section]` header.
    private static func removeDoomcoderSection(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var skipping = false

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == tomlSectionHeader {
                skipping = true
                // Also drop a preceding marker line, if any.
                if let last = out.last, last.trimmingCharacters(in: .whitespaces) == tomlManagedMarker {
                    out.removeLast()
                }
                i += 1
                continue
            }
            if skipping {
                if trimmed.hasPrefix("[") {
                    skipping = false
                    out.append(line)
                }
                i += 1
                continue
            }
            out.append(line)
            i += 1
        }
        return out.joined(separator: "\n")
    }
}
