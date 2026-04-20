import Foundation
import OSLog
import CryptoKit

// v2 installer — correct per-agent hook schemas, path-based identification
// (no x-doomcoder sentinel), recursive strip, backup-before-write, path heal.
//
// v1.9.1: install/uninstall run a real post-state verification contract
// (re-read the file from disk, assert every expected event maps to an
// existing dc-hook binary; on uninstall assert zero dc-hook references
// remain). On verification failure we revert from the backup we just
// took and surface a specific error. Every op emits one structured log
// line at category "installer" for post-hoc debugging.
struct AgentInstallerV2 {
    private static let logger = Logger(subsystem: "com.doomcoder", category: "installer")

    // MARK: - Helper binary path

    /// Stable path inside Application Support — survives Xcode rebuilds.
    private static var stablePath: String {
        AgentSupportDir.url.appendingPathComponent("dc-hook").path
    }

    /// Copies dc-hook from the app bundle to a stable, version-proof
    /// location inside ~/Library/Application Support/DoomCoder/. Hook
    /// configs always reference *this* path so they survive Xcode
    /// DerivedData moves and `/Applications` relocations.
    @discardableResult
    static func ensureStableHelper() -> Bool {
        AgentSupportDir.ensure()
        let dst = stablePath
        // Prefer bundle resource, fall back to /Applications location.
        let src: String? = Bundle.main.url(forResource: "dc-hook", withExtension: nil)?.path
            ?? {
                let app = "/Applications/DoomCoder.app/Contents/Resources/dc-hook"
                return FileManager.default.fileExists(atPath: app) ? app : nil
            }()
        guard let src, FileManager.default.fileExists(atPath: src) else {
            logger.warning("dc-hook source binary not found — skipping copy")
            return false
        }
        let fm = FileManager.default
        // Always overwrite so we keep the binary in sync with the running app.
        if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: dst) }
        do {
            try fm.copyItem(atPath: src, toPath: dst)
            // Ensure the binary is executable.
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst)
            logger.info("dc-hook copied to stable path: \(dst, privacy: .public)")
            return true
        } catch {
            logger.error("failed to copy dc-hook: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func helperBinaryPath() -> String {
        // Allow env-var override first (useful for tests / CI).
        if let override = ProcessInfo.processInfo.environment["DOOMCODER_HOOK_PATH"] {
            return override
        }
        // Prefer the stable Application Support copy.
        if FileManager.default.fileExists(atPath: stablePath) {
            return stablePath
        }
        // Fallback to bundle resource (first launch before copy).
        if let bundled = Bundle.main.url(forResource: "dc-hook", withExtension: nil) {
            return bundled.path
        }
        return "/Applications/DoomCoder.app/Contents/Resources/dc-hook"
    }

    // MARK: - Public API

    @discardableResult
    static func install(_ agent: TrackedAgent, folder: URL? = nil) -> Result<Void, Error> {
        // Pre-flight: ensure dc-hook binary is available
        guard ensureStableHelper() || FileManager.default.fileExists(atPath: helperBinaryPath()) else {
            return .failure(VerifyError.helperBinaryMissing)
        }

        let path = configPath(for: agent, folder: folder)

        // Pre-flight: check write permission
        let parentDir = (path as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: parentDir) &&
           !FileManager.default.isWritableFile(atPath: parentDir) {
            return .failure(VerifyError.configPermissionDenied(path))
        }

        let preHash = sha256(of: path) ?? "absent"
        let backupPath = backup(path)

        do {
            switch agent {
            case .claude:     try installClaude()
            case .cursor:     try installCursor()
            case .vscode:     try installVSCode()
            case .copilotCLI: try installCopilotCLI(folder: folder)
            }
            try verifyInstalled(agent: agent, at: path)
            let postHash = sha256(of: path) ?? "?"
            let n = expectedEvents(for: agent).count
            logger.notice("installer op=install agent=\(agent.rawValue, privacy: .public) pre_hash=\(preHash, privacy: .public) post_hash=\(postHash, privacy: .public) events_asserted=\(n)/\(n) backup=\(backupPath ?? "-", privacy: .public) outcome=ok")
            return .success(())
        } catch {
            // Attempt revert from the backup we took before writing.
            var revertNote = "no_backup"
            if let bp = backupPath, FileManager.default.fileExists(atPath: bp) {
                try? FileManager.default.removeItem(atPath: path)
                do {
                    try FileManager.default.copyItem(atPath: bp, toPath: path)
                    revertNote = "reverted"
                } catch {
                    revertNote = "revert_failed"
                }
            }
            logger.error("installer op=install agent=\(agent.rawValue, privacy: .public) pre_hash=\(preHash, privacy: .public) outcome=fail reason=\(error.localizedDescription, privacy: .public) revert=\(revertNote, privacy: .public)")
            return .failure(error)
        }
    }

    @discardableResult
    static func uninstall(_ agent: TrackedAgent, folder: URL? = nil) -> Result<Void, Error> {
        let path = configPath(for: agent, folder: folder)
        guard FileManager.default.fileExists(atPath: path) else {
            logger.notice("installer op=uninstall agent=\(agent.rawValue, privacy: .public) outcome=noop reason=no_file")
            return .success(())
        }
        let preHash = sha256(of: path) ?? "?"
        let backupPath = backup(path)

        do {
            var root = readJSON(at: path) ?? [:]
            let token = dcHookAgentToken(agent)
            stripDcHookEntries(&root, agentToken: token)
            pruneEmptyContainers(&root)
            try writeJSON(root, to: path, needsVersion: agent == .cursor || agent == .copilotCLI)
            try verifyUninstalled(at: path, agent: agent)
            let postHash = sha256(of: path) ?? "absent"
            logger.notice("installer op=uninstall agent=\(agent.rawValue, privacy: .public) pre_hash=\(preHash, privacy: .public) post_hash=\(postHash, privacy: .public) backup=\(backupPath ?? "-", privacy: .public) outcome=ok")
            return .success(())
        } catch {
            var revertNote = "no_backup"
            if let bp = backupPath, FileManager.default.fileExists(atPath: bp) {
                try? FileManager.default.removeItem(atPath: path)
                do {
                    try FileManager.default.copyItem(atPath: bp, toPath: path)
                    revertNote = "reverted"
                } catch {
                    revertNote = "revert_failed"
                }
            }
            logger.error("installer op=uninstall agent=\(agent.rawValue, privacy: .public) pre_hash=\(preHash, privacy: .public) outcome=fail reason=\(error.localizedDescription, privacy: .public) revert=\(revertNote, privacy: .public)")
            return .failure(error)
        }
    }

    /// Re-resolve the helper binary path in every installed agent config on launch.
    static func healAllPaths() {
        var healed = 0
        var files = 0
        for agent in TrackedAgent.allCases where agent != .copilotCLI {
            if isInstalled(agent) {
                files += 1
                if case .success = install(agent) { healed += 1 }
            }
        }
        for folder in CopilotCLIFolderManager.folders {
            if isInstalledCLI(folder: folder) {
                files += 1
                if case .success = install(.copilotCLI, folder: folder) { healed += 1 }
            }
        }
        logger.notice("heal op=paths healed=\(healed) files=\(files)")
    }

    // MARK: - Detection

    static func isInstalled(_ agent: TrackedAgent) -> Bool {
        switch agent {
        case .copilotCLI:
            return !CopilotCLIFolderManager.installedFolders().isEmpty
        case .vscode:
            // VSCode shares ~/.claude/settings.json with Claude. Detect by
            // presence of vscode-specific dc-hook command lines.
            return fileContainsDcHookFor(agent: "vscode", at: claudeSettingsPath())
        case .claude:
            return fileContainsDcHookFor(agent: "claude", at: claudeSettingsPath())
        case .cursor:
            return fileContainsDcHookFor(agent: "cursor", at: cursorHooksPath())
        }
    }

    static func isInstalledCLI(folder: URL) -> Bool {
        let path = folder.appendingPathComponent(".github/hooks/doomcoder.json").path
        return fileContainsDcHookFor(agent: "copilot_cli", at: path)
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

    // MARK: - Public verification

    /// Returns `.success` if hooks are correctly installed for `agent`, `.failure` otherwise.
    static func verifyInstalled(_ agent: TrackedAgent) -> Result<Void, Error> {
        let path = configPath(for: agent)
        do {
            try verifyInstalled(agent: agent, at: path)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Per-agent install implementations

    private static func installClaude() throws {
        let path = claudeSettingsPath()
        try ensureParentDir(path)
        var root = readJSON(at: path) ?? [:]

        // Strip only Claude dc-hook entries (preserve VS Code entries in shared file)
        stripDcHookEntries(&root, agentToken: "claude")
        pruneEmptyContainers(&root)

        // Build Claude hook block with nested matcher wrapper — ALL events
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let events = claudeEvents
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

        // Strip only Cursor dc-hook entries
        stripDcHookEntries(&root, agentToken: "cursor")
        pruneEmptyContainers(&root)

        // Cursor requires version: 1 and only "command" key (no "type") — ALL events
        root["version"] = 1
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let events = cursorEvents
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

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        // Add ALL VS Code events (PascalCase, matcher-group format).
        // Claude entries may already exist for the same event names —
        // we just add a separate dc-hook vscode entry alongside.
        let vscodeEvts = vscodeEvents
        for event in vscodeEvts {
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

        // Copilot CLI requires version: 1 and bash/cwd/timeoutSec keys — ALL events
        let events = copilotCLIEvents
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

    /// Complete event lists per agent — single source of truth.
    static let claudeEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionDenied",
        "Notification", "Stop", "StopFailure",
        "SubagentStart", "SubagentStop",
        "TaskCreated", "TaskCompleted",
        "PreCompact", "PostCompact",
        "FileChanged", "CwdChanged", "ConfigChange",
        "InstructionsLoaded", "Elicitation", "ElicitationResult",
        "WorktreeCreate", "WorktreeRemove"
    ]

    static let cursorEvents = [
        "sessionStart", "sessionEnd",
        "preToolUse", "postToolUse", "postToolUseFailure",
        "subagentStart", "subagentStop",
        "beforeShellExecution", "afterShellExecution",
        "beforeMCPExecution", "afterMCPExecution",
        "afterFileEdit", "beforeReadFile",
        "beforeSubmitPrompt", "preCompact", "stop",
        "afterAgentResponse", "afterAgentThought",
        "beforeTabFileRead", "afterTabFileEdit"
    ]

    static let vscodeEvents = [
        "SessionStart", "UserPromptSubmit",
        "PreToolUse", "PostToolUse",
        "PreCompact",
        "Stop", "SubagentStart", "SubagentStop"
    ]

    static let copilotCLIEvents = [
        "sessionStart", "sessionEnd",
        "userPromptSubmitted",
        "preToolUse", "postToolUse",
        "errorOccurred"
    ]

    private static func cmdFor(_ agent: String, _ event: String) -> String {
        let exe = helperBinaryPath()
        // Shell-quote the path so spaces (e.g. "Application Support") are safe.
        let quoted = exe.contains(" ") ? "\"\(exe)\"" : exe
        return "\(quoted) \(agent) \(event)"
    }

    // MARK: - Recursive dc-hook entry stripping (D2: path-based identification)
    //
    // Walk entire JSON tree. Any object whose `command` or `bash` value contains
    // our helper path (dc-hook) is a DoomCoder entry. Drop it. Prune up-tree.

    /// Strip dc-hook entries for a specific agent only. When `agentToken` is nil,
    /// strips ALL dc-hook entries (legacy behavior for full cleanup).
    static func stripDcHookEntries(_ node: inout [String: Any], agentToken: String? = nil) {
        let helperName = "dc-hook"
        let matchesDcHook: (String) -> Bool = { cmd in
            guard cmd.contains(helperName) else { return false }
            if let token = agentToken { return cmd.contains(token) }
            return true
        }
        for (key, value) in node {
            if var arr = value as? [[String: Any]] {
                arr.removeAll { obj in
                    if let cmd = obj["command"] as? String, matchesDcHook(cmd) { return true }
                    if let bash = obj["bash"] as? String, matchesDcHook(bash) { return true }
                    // Check nested "hooks" arrays (Claude matcher-group style)
                    if let innerHooks = obj["hooks"] as? [[String: Any]] {
                        let cleaned = innerHooks.filter { inner in
                            if let cmd = inner["command"] as? String, matchesDcHook(cmd) { return false }
                            if let bash = inner["bash"] as? String, matchesDcHook(bash) { return false }
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
                            if let cmd = inner["command"] as? String, matchesDcHook(cmd) { return true }
                            if let bash = inner["bash"] as? String, matchesDcHook(bash) { return true }
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
                stripDcHookEntries(&dict, agentToken: agentToken)
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

    /// Returns true if the JSON file at `path` contains a dc-hook command
    /// string that also mentions the given agent token (e.g. "cursor",
    /// "claude", "vscode", "copilot_cli"). Used to distinguish Claude vs
    /// VSCode entries when both share ~/.claude/settings.json.
    private static func fileContainsDcHookFor(agent token: String, at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
        var found = false
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            walkCommands(obj) { cmd in
                if cmd.contains("dc-hook") && cmd.contains(token) { found = true }
            }
        } else if let text = String(data: data, encoding: .utf8) {
            // Fallback for malformed files — still detect presence.
            return text.contains("dc-hook") && text.contains(token)
        }
        return found
    }

    // MARK: - Verification contract (E1/E2)

    /// Expected event names per agent — mirrors the per-agent event arrays.
    static func expectedEvents(for agent: TrackedAgent) -> [String] {
        switch agent {
        case .claude:     return claudeEvents
        case .cursor:     return cursorEvents
        case .vscode:     return vscodeEvents
        case .copilotCLI: return copilotCLIEvents
        }
    }

    enum VerifyError: LocalizedError {
        case fileMissing
        case parseError
        case missingEvent(String)
        case badHelperPath(String)
        case residualDcHook
        case unexpectedStructure
        case configPermissionDenied(String)
        case agentNotInstalled(TrackedAgent)
        case helperBinaryMissing

        var errorDescription: String? {
            switch self {
            case .fileMissing:
                return "Config file was not created — check that the parent directory exists and is writable."
            case .parseError:
                return "Config file contains invalid JSON — it may have been corrupted. Check the backup in ~/Library/Application Support/DoomCoder/backups/."
            case .missingEvent(let e):
                return "Hook event '\(e)' is missing from the config. Try uninstalling and reinstalling."
            case .badHelperPath(let p):
                return "dc-hook binary not found at '\(p)'. Try reinstalling DoomCoder from the DMG."
            case .residualDcHook:
                return "Some hook entries could not be removed. Open the config file manually to clean up."
            case .unexpectedStructure:
                return "Config file has an unexpected structure. It may have been edited by another tool."
            case .configPermissionDenied(let p):
                return "Cannot write to '\(p)' — check file permissions (chmod 644)."
            case .agentNotInstalled(let a):
                return "\(a.displayName) does not appear to be installed on this system."
            case .helperBinaryMissing:
                return "dc-hook binary not found in the app bundle. Try reinstalling DoomCoder."
            }
        }

        /// Short user-facing suggestion for the configure window.
        var recoverySuggestion: String? {
            switch self {
            case .fileMissing, .parseError, .unexpectedStructure:
                return "Try using the Repair button to reset hooks."
            case .missingEvent:
                return "Reinstall hooks to restore missing events."
            case .badHelperPath, .helperBinaryMissing:
                return "Reinstall DoomCoder from the latest release."
            case .residualDcHook:
                return "Use 'Show Config' to manually inspect the file."
            case .configPermissionDenied:
                return "Fix file permissions in Terminal, then retry."
            case .agentNotInstalled:
                return nil
            }
        }
    }

    private static func verifyInstalled(agent: TrackedAgent, at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw VerifyError.fileMissing }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw VerifyError.parseError }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw VerifyError.parseError }

        let token = dcHookAgentToken(agent)
        var seenEvents = Set<String>()
        var helperPaths = Set<String>()
        walkCommandsWithKey(root) { key, cmd in
            guard cmd.contains("dc-hook"), cmd.contains(token) else { return }
            seenEvents.insert(key)
            // Extract binary path — may be shell-quoted when path contains spaces.
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

        for event in expectedEvents(for: agent) {
            if !seenEvents.contains(event) { throw VerifyError.missingEvent(event) }
        }
        for bin in helperPaths {
            // Only assert if absolute path — relative paths (rare) can't be checked reliably.
            if bin.hasPrefix("/") && !FileManager.default.isExecutableFile(atPath: bin) {
                throw VerifyError.badHelperPath(bin)
            }
        }
    }

    private static func verifyUninstalled(at path: String, agent: TrackedAgent) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let token = dcHookAgentToken(agent)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if let text = String(data: data, encoding: .utf8),
               text.contains("dc-hook") && text.contains(token) {
                throw VerifyError.residualDcHook
            }
            return
        }
        var residual = false
        walkCommands(root) { cmd in
            if cmd.contains("dc-hook") && cmd.contains(token) { residual = true }
        }
        if residual { throw VerifyError.residualDcHook }
    }

    private static func dcHookAgentToken(_ agent: TrackedAgent) -> String {
        switch agent {
        case .claude:     return "claude"
        case .cursor:     return "cursor"
        case .vscode:     return "vscode"
        case .copilotCLI: return "copilot_cli"
        }
    }

    /// Walks every `command` and `bash` string in an arbitrary JSON tree,
    /// invoking `visit(cmd)` for each. Used for residual-detection during
    /// uninstall verification.
    private static func walkCommands(_ node: Any, visit: (String) -> Void) {
        if let dict = node as? [String: Any] {
            if let cmd = dict["command"] as? String { visit(cmd) }
            if let bash = dict["bash"] as? String { visit(bash) }
            for (_, v) in dict { walkCommands(v, visit: visit) }
        } else if let arr = node as? [Any] {
            for v in arr { walkCommands(v, visit: visit) }
        }
    }

    /// Walks the hooks tree tracking the event-name key associated with each
    /// `command`/`bash` string. Used for install-verification to map seen
    /// dc-hook entries back to the expected event set.
    private static func walkCommandsWithKey(_ node: Any, currentKey: String? = nil, visit: (String, String) -> Void) {
        if let dict = node as? [String: Any] {
            // "command" / "bash" at this node belongs to the nearest enclosing event key.
            if let cmd = dict["command"] as? String, let key = currentKey { visit(key, cmd) }
            if let bash = dict["bash"] as? String, let key = currentKey { visit(key, bash) }
            // For Claude matcher-group style, nested "hooks": [{command, ...}] inherits outer key.
            for (k, v) in dict {
                let nextKey: String? = (k == "hooks") ? currentKey : k
                walkCommandsWithKey(v, currentKey: nextKey, visit: visit)
            }
        } else if let arr = node as? [Any] {
            for v in arr { walkCommandsWithKey(v, currentKey: currentKey, visit: visit) }
        }
    }

    private static func sha256(of path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
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

    @discardableResult
    static func backup(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupDir = AgentSupportDir.url.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
        let dst = backupDir.appendingPathComponent("\(name).\(ts)").path
        do {
            try FileManager.default.copyItem(atPath: path, toPath: dst)
            return dst
        } catch {
            // Secondary fallback — sibling backup next to the file so we at
            // least have something to revert from if the support-dir copy
            // fails (e.g. sandboxed contexts).
            let sibling = "\(path).doomcoder-backup-\(ts)"
            try? FileManager.default.copyItem(atPath: path, toPath: sibling)
            return FileManager.default.fileExists(atPath: sibling) ? sibling : nil
        }
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
