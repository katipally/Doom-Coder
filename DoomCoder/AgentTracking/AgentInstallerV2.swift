import Foundation
import OSLog

// v2 installer — correct per-agent hook schemas, path-based identification
// (no x-doomcoder sentinel), recursive strip, backup-before-write, path heal.
struct AgentInstallerV2 {
    private static let logger = Logger(subsystem: "com.doomcoder", category: "installer-v2")

    // MARK: - Helper binary path

    static func helperBinaryPath() -> String {
        if let bundled = Bundle.main.url(forResource: "dc-hook", withExtension: nil) {
            return bundled.path
        }
        if let override = ProcessInfo.processInfo.environment["DOOMCODER_HOOK_PATH"] {
            return override
        }
        return "/Applications/DoomCoder.app/Contents/Resources/dc-hook"
    }

    // MARK: - Public API

    @discardableResult
    static func install(_ agent: TrackedAgent, folder: URL? = nil) -> Result<Void, Error> {
        do {
            switch agent {
            case .claude:     try installClaude()
            case .cursor:     try installCursor()
            case .vscode:     try installVSCode()
            case .copilotCLI: try installCopilotCLI(folder: folder)
            }
            logger.info("Installed hooks for \(agent.rawValue, privacy: .public)")
            return .success(())
        } catch {
            logger.error("install(\(agent.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    @discardableResult
    static func uninstall(_ agent: TrackedAgent, folder: URL? = nil) -> Result<Void, Error> {
        do {
            let path = configPath(for: agent, folder: folder)
            guard FileManager.default.fileExists(atPath: path) else { return .success(()) }
            backup(path)
            var root = readJSON(at: path) ?? [:]
            stripDcHookEntries(&root)
            pruneEmptyContainers(&root)
            try writeJSON(root, to: path, needsVersion: agent == .cursor || agent == .copilotCLI)
            logger.info("Uninstalled hooks for \(agent.rawValue, privacy: .public)")
            return .success(())
        } catch {
            logger.error("uninstall(\(agent.rawValue, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    /// Re-resolve the helper binary path in every installed agent config on launch.
    static func healAllPaths() {
        for agent in TrackedAgent.allCases where agent != .copilotCLI {
            if isInstalled(agent) {
                _ = install(agent)
            }
        }
        // Copilot CLI: heal each registered folder
        for folder in CopilotCLIFolderManager.folders {
            if isInstalledCLI(folder: folder) {
                _ = install(.copilotCLI, folder: folder)
            }
        }
    }

    // MARK: - Detection

    static func isInstalled(_ agent: TrackedAgent) -> Bool {
        switch agent {
        case .copilotCLI: return false // use isInstalledCLI(folder:)
        default:
            let path = configPath(for: agent)
            return fileContainsDcHook(at: path)
        }
    }

    static func isInstalledCLI(folder: URL) -> Bool {
        let path = folder.appendingPathComponent(".github/hooks/doomcoder.json").path
        return fileContainsDcHook(at: path)
    }

    // MARK: - Config paths

    static func configPath(for agent: TrackedAgent, folder: URL? = nil) -> String {
        switch agent {
        case .claude:     return claudeSettingsPath()
        case .cursor:     return cursorHooksPath()
        case .vscode:     return claudeSettingsPath() // VSCode reads ~/.claude/settings.json natively
        case .copilotCLI:
            let base = folder ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            return base.appendingPathComponent(".github/hooks/doomcoder.json").path
        }
    }

    static func claudeSettingsPath() -> String { NSHomeDirectory() + "/.claude/settings.json" }
    static func cursorHooksPath()   -> String { NSHomeDirectory() + "/.cursor/hooks.json" }

    // MARK: - Per-agent install implementations

    private static func installClaude() throws {
        let path = claudeSettingsPath()
        try ensureParentDir(path)
        var root = readJSON(at: path) ?? [:]
        backup(path)

        // Strip any previous dc-hook entries
        stripDcHookEntries(&root)
        pruneEmptyContainers(&root)

        // Build Claude hook block with nested matcher wrapper
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let events = ["SessionStart", "Notification", "Stop", "SubagentStop"]
        for event in events {
            let entry: [String: Any] = [
                "matcher": "*",
                "hooks": [
                    [
                        "type": "command",
                        "command": cmdFor("claude", event)
                    ] as [String: Any]
                ]
            ]
            var arr = (hooks[event] as? [[String: Any]]) ?? []
            arr.append(entry)
            hooks[event] = arr
        }
        root["hooks"] = hooks
        try writeJSON(root, to: path, needsVersion: false)
    }

    private static func installCursor() throws {
        let path = cursorHooksPath()
        try ensureParentDir(path)
        var root = readJSON(at: path) ?? [:]
        backup(path)

        stripDcHookEntries(&root)
        pruneEmptyContainers(&root)

        // Cursor requires version: 1 and only "command" key (no "type")
        root["version"] = 1
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let events = ["sessionStart", "afterAgentResponse", "stop"]
        for event in events {
            let entry: [String: Any] = ["command": cmdFor("cursor", event)]
            var arr = (hooks[event] as? [[String: Any]]) ?? []
            arr.append(entry)
            hooks[event] = arr
        }
        root["hooks"] = hooks
        try writeJSON(root, to: path, needsVersion: true)
    }

    private static func installVSCode() throws {
        // VSCode Copilot reads ~/.claude/settings.json natively via chat.hookFilesLocations
        // We share the same file as Claude but add VSCode-specific events
        let path = claudeSettingsPath()
        try ensureParentDir(path)
        var root = readJSON(at: path) ?? [:]
        backup(path)

        // Only strip dc-hook entries, preserve Claude's entries since they share the file
        // We add VSCode-specific events that Claude also supports
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        // Add events that are useful for VSCode but may not overlap with Claude
        // SessionStart, Stop, SubagentStop are shared with Claude install
        // We ensure they exist (Claude install handles them, this is additive)
        let vscodeEvents = ["SessionStart", "Stop", "SubagentStop"]
        for event in vscodeEvents {
            var arr = (hooks[event] as? [[String: Any]]) ?? []
            // Check if dc-hook vscode entry already present
            let alreadyHas = arr.contains { group in
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    return innerHooks.contains { ($0["command"] as? String)?.contains("dc-hook") == true && ($0["command"] as? String)?.contains("vscode") == true }
                }
                return false
            }
            if !alreadyHas {
                let entry: [String: Any] = [
                    "matcher": "*",
                    "hooks": [
                        [
                            "type": "command",
                            "command": cmdFor("vscode", event)
                        ] as [String: Any]
                    ]
                ]
                arr.append(entry)
                hooks[event] = arr
            }
        }
        root["hooks"] = hooks
        try writeJSON(root, to: path, needsVersion: false)
    }

    private static func installCopilotCLI(folder: URL?) throws {
        guard let folder = folder else {
            throw InstallerError.missingFolder
        }
        let hooksDir = folder.appendingPathComponent(".github/hooks")
        let path = hooksDir.appendingPathComponent("doomcoder.json").path
        try ensureParentDir(path)
        backup(path)

        // Copilot CLI requires version: 1 and bash/cwd/timeoutSec keys
        let events = ["sessionStart", "sessionEnd", "userPromptSubmitted", "errorOccurred"]
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [[
                "type": "command",
                "bash": cmdFor("copilot_cli", event),
                "cwd": ".",
                "timeoutSec": 10
            ] as [String: Any]]
        }
        let root: [String: Any] = ["version": 1, "hooks": hooks]
        try writeJSON(root, to: path, needsVersion: true)
    }

    // MARK: - Hook command builder

    private static func cmdFor(_ agent: String, _ event: String) -> String {
        let exe = helperBinaryPath()
        // Use positional args: dc-hook <agent> <event>
        return "\(exe) \(agent) \(event)"
    }

    // MARK: - Recursive dc-hook entry stripping (D2: path-based identification)
    //
    // Walk entire JSON tree. Any object whose `command` or `bash` value contains
    // our helper path (dc-hook) is a DoomCoder entry. Drop it. Prune up-tree.

    static func stripDcHookEntries(_ node: inout [String: Any]) {
        let helperName = "dc-hook"
        for (key, value) in node {
            if var arr = value as? [[String: Any]] {
                arr.removeAll { obj in
                    if let cmd = obj["command"] as? String, cmd.contains(helperName) { return true }
                    if let bash = obj["bash"] as? String, bash.contains(helperName) { return true }
                    // Check nested "hooks" arrays (Claude matcher-group style)
                    if let innerHooks = obj["hooks"] as? [[String: Any]] {
                        let cleaned = innerHooks.filter { inner in
                            if let cmd = inner["command"] as? String, cmd.contains(helperName) { return false }
                            if let bash = inner["bash"] as? String, bash.contains(helperName) { return false }
                            return true
                        }
                        if cleaned.isEmpty { return true }
                    }
                    return false
                }
                // Also handle groups where only some inner hooks are ours
                arr = arr.map { obj in
                    var mutable = obj
                    if var innerHooks = mutable["hooks"] as? [[String: Any]] {
                        innerHooks.removeAll { inner in
                            if let cmd = inner["command"] as? String, cmd.contains(helperName) { return true }
                            if let bash = inner["bash"] as? String, bash.contains(helperName) { return true }
                            return false
                        }
                        mutable["hooks"] = innerHooks
                    }
                    return mutable
                }
                // Remove groups with empty inner hooks arrays
                arr.removeAll { obj in
                    if let innerHooks = obj["hooks"] as? [[String: Any]], innerHooks.isEmpty { return true }
                    return false
                }
                node[key] = arr
            } else if var dict = value as? [String: Any] {
                stripDcHookEntries(&dict)
                node[key] = dict
            }
        }
    }

    static func pruneEmptyContainers(_ node: inout [String: Any]) {
        for (key, value) in node {
            if let arr = value as? [Any], arr.isEmpty {
                node.removeValue(forKey: key)
            } else if var dict = value as? [String: Any] {
                pruneEmptyContainers(&dict)
                if dict.isEmpty { node.removeValue(forKey: key) }
                else { node[key] = dict }
            }
        }
    }

    // MARK: - Detection helper

    private static func fileContainsDcHook(at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("dc-hook")
    }

    // MARK: - JSON I/O

    private static func readJSON(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func writeJSON(_ root: [String: Any], to path: String, needsVersion: Bool) throws {
        var final = root
        if needsVersion { final["version"] = final["version"] ?? 1 }
        let data = try JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func ensureParentDir(_ path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    }

    static func backup(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dst = "\(path).doomcoder-backup-\(ts)"
        try? FileManager.default.copyItem(atPath: path, toPath: dst)
    }

    // MARK: - Errors

    enum InstallerError: LocalizedError {
        case missingFolder

        var errorDescription: String? {
            switch self {
            case .missingFolder: return "No project folder selected for Copilot CLI hooks."
            }
        }
    }
}
