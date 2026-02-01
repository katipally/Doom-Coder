import Foundation
import OSLog

/// Actor-serialized config file backend for safe concurrent access.
///
/// Claude Code and VS Code Copilot Agent both read `~/.claude/settings.json`.
/// This actor ensures only one install/uninstall/validate operation runs at a
/// time per file, preventing concurrent corruption.
///
/// Each agent's entries are identified by a token embedded in the dc-hook
/// command string (e.g. `dc-hook claude`, `dc-hook vscode`), so agents can
/// coexist in the same file without stepping on each other.
actor HookConfigBackend {
    static let shared = HookConfigBackend()

    private let logger = Logger(subsystem: "com.doomcoder", category: "config-backend")
    private let fm = FileManager.default

    // MARK: - Transaction (serialized read-modify-write)

    /// Performs a serialized read-modify-write on a JSON config file.
    /// The mutation closure receives the current JSON root (or empty dict if
    /// file doesn't exist) and can modify it in place. The result is written
    /// back atomically with a backup taken before the write.
    func transaction(
        path: String,
        needsVersion: Bool = false,
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws {
        try ensureParentDir(path)
        let backupPath = backup(path)

        var root = readJSON(at: path) ?? [:]
        try mutate(&root)
        try writeJSON(root, to: path, needsVersion: needsVersion)

        logger.info("transaction path=\(path, privacy: .public) backup=\(backupPath ?? "none", privacy: .public)")
    }

    /// Strips only DoomCoder-owned entries for a specific agent token, then
    /// prunes empty containers. Pass `nil` to strip ALL dc-hook entries.
    func stripEntries(path: String, agentToken: String?) throws {
        guard fm.fileExists(atPath: path) else { return }
        try transaction(path: path) { root in
            AgentInstallerV2.stripDcHookEntries(&root, agentToken: agentToken)
            AgentInstallerV2.pruneEmptyContainers(&root)
        }
    }

    /// Validates that dc-hook entries for the given agent exist and point to
    /// a valid binary. Returns an array of issues found (empty = all good).
    func validate(path: String, agent: TrackedAgent) -> [HookValidationIssue] {
        guard fm.fileExists(atPath: path) else {
            return [.fileMissing(path)]
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [.parseError(path)]
        }

        let token = agentTokenString(agent)
        var seenEvents = Set<String>()
        var helperPaths = Set<String>()

        walkCommandsWithKey(root) { key, cmd in
            guard cmd.contains("dc-hook"), cmd.contains(token) else { return }
            seenEvents.insert(key)
            let trimmed = cmd.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\"") {
                let inner = trimmed.dropFirst()
                if let closeIdx = inner.firstIndex(of: "\"") {
                    helperPaths.insert(String(inner[inner.startIndex..<closeIdx]))
                }
            } else if let bin = trimmed.split(separator: " ").first {
                helperPaths.insert(String(bin))
            }
        }

        var issues: [HookValidationIssue] = []
        let expected = AgentInstallerV2.expectedEvents(for: agent)
        for event in expected where !seenEvents.contains(event) {
            issues.append(.missingEvent(event, agent: agent))
        }
        for bin in helperPaths where bin.hasPrefix("/") && !fm.isExecutableFile(atPath: bin) {
            issues.append(.badHelperPath(bin))
        }
        return issues
    }

    /// Returns true if the given agent has dc-hook entries in the file.
    func hasEntries(path: String, agent: TrackedAgent) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        let token = agentTokenString(agent)
        var found = false
        walkCommands(root) { cmd in
            if cmd.contains("dc-hook") && cmd.contains(token) { found = true }
        }
        return found
    }

    // MARK: - Backup

    @discardableResult
    func backup(_ path: String) -> String? {
        AgentInstallerV2.backup(path)
    }

    // MARK: - Agent tokens

    func agentTokenString(_ agent: TrackedAgent) -> String {
        switch agent {
        case .claude:     return "claude"
        case .cursor:     return "cursor"
        case .vscode:     return "vscode"
        case .copilotCLI: return "copilot_cli"
        }
    }

    // MARK: - JSON I/O (private)

    private func readJSON(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func writeJSON(_ root: [String: Any], to path: String, needsVersion: Bool) throws {
        var final = root
        if needsVersion { final["version"] = final["version"] ?? 1 }
        let data = try JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func ensureParentDir(_ path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
    }

    // MARK: - Command walkers

    private func walkCommands(_ node: Any, visit: (String) -> Void) {
        if let dict = node as? [String: Any] {
            if let cmd = dict["command"] as? String { visit(cmd) }
            if let bash = dict["bash"] as? String { visit(bash) }
            for (_, v) in dict { walkCommands(v, visit: visit) }
        } else if let arr = node as? [Any] {
            for v in arr { walkCommands(v, visit: visit) }
        }
    }

    private func walkCommandsWithKey(_ node: Any, currentKey: String? = nil, visit: (String, String) -> Void) {
        if let dict = node as? [String: Any] {
            if let cmd = dict["command"] as? String, let key = currentKey { visit(key, cmd) }
            if let bash = dict["bash"] as? String, let key = currentKey { visit(key, bash) }
            for (k, v) in dict {
                let nextKey: String? = (k == "hooks") ? currentKey : k
                walkCommandsWithKey(v, currentKey: nextKey, visit: visit)
            }
        } else if let arr = node as? [Any] {
            for v in arr { walkCommandsWithKey(v, currentKey: currentKey, visit: visit) }
        }
    }
}

// MARK: - Validation issues

enum HookValidationIssue: CustomStringConvertible {
    case fileMissing(String)
    case parseError(String)
    case missingEvent(String, agent: TrackedAgent)
    case badHelperPath(String)

    var description: String {
        switch self {
        case .fileMissing(let p):        return "Config file not found: \(p)"
        case .parseError(let p):         return "Failed to parse JSON: \(p)"
        case .missingEvent(let e, let a): return "\(a.displayName): hook missing for event '\(e)'"
        case .badHelperPath(let p):      return "dc-hook binary not found at: \(p)"
        }
    }

    var isBlocking: Bool {
        switch self {
        case .fileMissing, .parseError: return true
        case .missingEvent, .badHelperPath: return false
        }
    }
}
