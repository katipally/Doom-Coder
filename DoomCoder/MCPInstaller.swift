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
// Supported agents in v1.8.3:
//   • Cursor       — ~/.cursor/mcp.json (JSON)
//   • Claude Code  — ~/.claude.json (JSON)
//   • Copilot CLI  — ~/.copilot/mcp-config.json (JSON)
//
// v1.8.3: dropped Windsurf/VS Code/Gemini/Codex cases. Users on those
// agents follow the generic Install Anywhere pane instead.

enum MCPInstaller {

    enum Agent: String, CaseIterable, Identifiable {
        case cursor
        case claudeCode = "claude-code"
        case copilotCLI = "copilot-cli"
        var id: String { rawValue }

        var catalogId: String {
            switch self {
            case .cursor:     return "cursor"
            case .claudeCode: return "claude-code"
            case .copilotCLI: return "copilot-cli"
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
            case .claudeCode:
                return "Adds a \"doomcoder\" MCP server to ~/.claude.json. Claude Code connects on next launch and calls the `dc` tool per the rules snippet we install alongside."
            case .copilotCLI:
                return "Adds a \"doomcoder\" MCP server to ~/.copilot/mcp-config.json. Copilot CLI connects on next launch; the rules snippet tells it when to call `dc`."
            }
        }

        /// Path to the agent's MCP config file in the user's home.
        var configPath: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .cursor:
                return home.appendingPathComponent(".cursor/mcp.json")
            case .claudeCode:
                return home.appendingPathComponent(".claude.json")
            case .copilotCLI:
                return home.appendingPathComponent(".copilot/mcp-config.json")
            }
        }

        /// Where we park timestamped backups before every mutation.
        var backupDir: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".doomcoder/backups/\(rawValue)", isDirectory: true)
        }

        var isTOML: Bool { false }

        /// Human-readable key that identifies "our" server entry inside the
        /// config. Same across all agents for easy grep + uninstall.
        static let serverKey = "doomcoder"
    }

    /// Three-state badge shown in the UI + two special error states.
    ///
    /// - `notInstalled`: config file missing, or present but no doomcoder entry.
    /// - `configWritten`: our entry is on disk (sentinel present) but we
    ///   haven't seen the agent load it yet. Most likely the agent needs a
    ///   restart.
    /// - `live`: our entry is on disk **and** the MCP server fired an
    ///   `mcp-hello` on its `initialize` RPC within the last 10 minutes —
    ///   proof that the agent picked up the config.
    /// - `modified`: an entry named "doomcoder" exists but the `doomcoder-managed`
    ///   sentinel is absent — user-authored, we won't touch it.
    /// - `missingConfig`: config file present but unreadable / malformed.
    enum Status: String { case notInstalled, configWritten, live, modified, missingConfig }

    /// Windows of "live" validity. If no hello seen within this many seconds
    /// the status falls back to `.configWritten`.
    private static let liveWindow: TimeInterval = 10 * 60

    enum InstallError: Error {
        case writeFailed(URL, underlying: Error)
        case malformedConfig(URL)
        case preflightFailed([String])
    }

    // MARK: - Preflight
    //
    // A dry run before install so UI can refuse with a clear list of failures
    // instead of throwing deep in the writer. Each check is cheap and
    // independent; we collect all failures so the user sees every issue at
    // once rather than fixing one, retrying, and hitting the next.

    struct PreflightIssue: Identifiable, Hashable {
        let id: String     // stable key for the UI
        let severity: Severity
        let summary: String
        let detail: String

        enum Severity { case warning, blocker }
    }

    static func preflight(_ agent: Agent) -> [PreflightIssue] {
        var issues: [PreflightIssue] = []
        let fm = FileManager.default

        // 1) python3 availability — we invoke /usr/bin/python3 directly so
        //    the system stub must be present. On fresh macOS boxes without
        //    CLT installed it prompts instead of running; warn the user.
        if !fm.isExecutableFile(atPath: "/usr/bin/python3") {
            issues.append(PreflightIssue(
                id: "python3",
                severity: .blocker,
                summary: "/usr/bin/python3 not executable",
                detail: "Install Command Line Tools with `xcode-select --install` and retry."
            ))
        }

        // 2) Parent directory writable. We createDirectory later, but if the
        //    user's home is read-only (e.g. managed device) we want to say so.
        let parent = agent.configPath.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.path) && !fm.isWritableFile(atPath: parent.path) {
            issues.append(PreflightIssue(
                id: "writable",
                severity: .blocker,
                summary: "Cannot write to \(parent.path)",
                detail: "Check folder permissions — DoomCoder must write the MCP config there."
            ))
        }

        // 3) Existing config must parse cleanly if it's there. Malformed JSON
        //    from a prior hand-edit would be silently blown away otherwise.
        if fm.fileExists(atPath: agent.configPath.path),
           let data = try? Data(contentsOf: agent.configPath),
           !data.isEmpty {
            if agent.isTOML {
                if String(data: data, encoding: .utf8) == nil {
                    issues.append(PreflightIssue(
                        id: "config-encoding",
                        severity: .blocker,
                        summary: "Existing config is not valid UTF-8",
                        detail: agent.configPath.path
                    ))
                }
            } else {
                if (try? JSONSerialization.jsonObject(with: data)) == nil {
                    issues.append(PreflightIssue(
                        id: "config-json",
                        severity: .blocker,
                        summary: "Existing config is not valid JSON",
                        detail: "Fix or delete \(agent.configPath.path) and retry."
                    ))
                }
            }
        }

        // 4) Cursor-specific: warn about project-level shadows that would
        //    override the global install silently (see detectCursorProjectShadows).
        if agent == .cursor {
            let shadows = detectCursorProjectShadows()
            if !shadows.isEmpty {
                issues.append(PreflightIssue(
                    id: "cursor-shadow",
                    severity: .warning,
                    summary: "Project-level Cursor MCP configs detected (\(shadows.count))",
                    detail: "These silently override ~/.cursor/mcp.json. Consider installing in each project or merging the global server entry into them:\n" +
                        shadows.prefix(5).map { "• \($0.path)" }.joined(separator: "\n")
                ))
            }
        }

        // 5) mcp.py must be deployable. Bail if ~/.doomcoder is a stray file.
        let dcDir = MCPRuntime.directory
        if fm.fileExists(atPath: dcDir.path) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: dcDir.path, isDirectory: &isDir)
            if !isDir.boolValue {
                issues.append(PreflightIssue(
                    id: "dcdir",
                    severity: .blocker,
                    summary: "~/.doomcoder exists but is not a directory",
                    detail: "Remove it and retry; DoomCoder keeps its scripts there."
                ))
            }
        }

        return issues
    }

    // MARK: - Cursor project-shadow scan
    //
    // Cursor's MCP config resolution is project-scoped: if `.cursor/mcp.json`
    // exists in the workspace root, it *replaces* (not merges) the global
    // `~/.cursor/mcp.json` for that workspace. This is the "installed but
    // nothing happens" failure we've been seeing — the user installs the
    // global config, opens Cursor in a project with an existing shadow, and
    // the doomcoder entry is never loaded.
    //
    // We scan a small set of likely locations (recent Finder, Xcode, and
    // common dev roots) rather than walking the whole home directory, which
    // would be both slow and scary on big trees.

    static func detectCursorProjectShadows() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Where developers typically keep repos. We never descend deeper than
        // 3 levels — a typical `~/Code/Work/my-app/.cursor/mcp.json` fits.
        let roots: [URL] = [
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Developer"),
            home.appendingPathComponent("Projects"),
            home.appendingPathComponent("Code"),
            home.appendingPathComponent("Workspace"),
            home.appendingPathComponent("src"),
        ].filter { fm.fileExists(atPath: $0.path) }

        var hits: [URL] = []
        for root in roots {
            hits.append(contentsOf: scanForCursorShadows(root: root, depth: 0, maxDepth: 3))
            if hits.count > 50 { break } // hard cap
        }
        return hits
    }

    private static func scanForCursorShadows(root: URL, depth: Int, maxDepth: Int) -> [URL] {
        let fm = FileManager.default
        let shadow = root.appendingPathComponent(".cursor/mcp.json")
        var hits: [URL] = []
        if fm.fileExists(atPath: shadow.path) {
            hits.append(shadow)
        }
        guard depth < maxDepth else { return hits }
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return hits }
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            // Skip obvious non-repo clutter to keep scans fast.
            let name = child.lastPathComponent
            if name == "node_modules" || name == ".git" || name == "Library"
                || name == "DerivedData" || name.hasPrefix(".") { continue }
            hits.append(contentsOf: scanForCursorShadows(root: child, depth: depth + 1, maxDepth: maxDepth))
        }
        return hits
    }

    // MARK: - Install id

    /// Stable-per-install UUID stamped into the MCP command line. The script
    /// echoes it back on its `mcp-hello` so we can correlate "the install we
    /// just wrote" with "the process that came alive."
    static func installId(for agent: Agent) -> String? {
        UserDefaults.standard.string(forKey: "dc.mcp.installId.\(agent.rawValue)")
    }

    private static func setInstallId(_ id: String?, for agent: Agent) {
        let key = "dc.mcp.installId.\(agent.rawValue)"
        if let id { UserDefaults.standard.set(id, forKey: key) }
        else      { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Called by `AgentStatusManager.ingestHello` — persists the hello
    /// timestamp so the 3-state badge stays correct across relaunches.
    static func recordHello(agent catalogId: String, installId: String) {
        guard let agent = Agent.allCases.first(where: { $0.catalogId == catalogId }) else { return }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970,
                                  forKey: "dc.mcp.hello.\(agent.rawValue).\(installId)")
    }

    private static func latestHello(for agent: Agent) -> Date? {
        guard let id = installId(for: agent) else { return nil }
        let ts = UserDefaults.standard.double(forKey: "dc.mcp.hello.\(agent.rawValue).\(id)")
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
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
        let onDisk: Status
        if agent.isTOML {
            guard let text = String(data: data, encoding: .utf8) else { return .missingConfig }
            onDisk = text.contains(tomlSectionHeader) ? .configWritten : .notInstalled
        } else {
            guard
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let servers = obj["mcpServers"] as? [String: Any],
                let entry = servers[Agent.serverKey] as? [String: Any]
            else {
                return .notInstalled
            }
            // We only own entries tagged with the sentinel. Anything else is
            // user-authored; we report `.modified` and refuse to clobber.
            onDisk = (entry["doomcoder-managed"] as? Bool == true) ? .configWritten : .modified
        }

        // Promote to .live if the MCP server fired a hello recently.
        if onDisk == .configWritten,
           let hello = latestHello(for: agent),
           Date.now.timeIntervalSince(hello) < liveWindow {
            return .live
        }
        return onDisk
    }

    // MARK: - Install

    @discardableResult
    static func install(_ agent: Agent) throws -> URL? {
        // Run preflight first so we refuse cleanly on known-bad state
        // instead of corrupting files mid-write or crashing deeper in JSON
        // serialization. Warnings don't block install — only blockers do.
        let issues = preflight(agent).filter { $0.severity == .blocker }
        if !issues.isEmpty {
            throw InstallError.preflightFailed(issues.map { "\($0.summary): \($0.detail)" })
        }

        let fm = FileManager.default
        try fm.createDirectory(at: agent.configPath.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        let backupURL = try backup(agent)

        // Fresh install-id per install so the hello handshake can distinguish
        // "alive from this install" from "alive from a stale prior install."
        let installId = UUID().uuidString
        setInstallId(installId, for: agent)

        if agent.isTOML {
            try writeTOML(for: agent, installId: installId)
        } else {
            try writeJSON(for: agent, installId: installId)
        }
        // Poke the mtime so editors with config-watchers (VS Code) re-read
        // without a manual restart when possible.
        try? fm.setAttributes([.modificationDate: Date.now], ofItemAtPath: agent.configPath.path)
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
        setInstallId(nil, for: agent)
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

    private static func writeJSON(for agent: Agent, installId: String) throws {
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
        let invocation = MCPRuntime.invocation(agent: agent.catalogId, installId: installId)
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

    private static func writeTOML(for agent: Agent, installId: String) throws {
        let fm = FileManager.default
        var existing: String = ""
        if fm.fileExists(atPath: agent.configPath.path),
           let text = try? String(contentsOf: agent.configPath, encoding: .utf8) {
            existing = text
        }

        let stripped = removeDoomcoderSection(from: existing)

        let invocation = MCPRuntime.invocation(agent: agent.catalogId, installId: installId)
        // Escape both backslash and double-quote per TOML basic-string rules;
        // prior versions only escaped the quote, which would corrupt any path
        // containing a literal backslash (rare on macOS but defensive).
        func tomlEscape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let argsLiteral = invocation.args
            .map { "\"\(tomlEscape($0))\"" }
            .joined(separator: ", ")

        let block = """

        \(tomlManagedMarker)
        \(tomlSectionHeader)
        command = "\(tomlEscape(invocation.command))"
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
