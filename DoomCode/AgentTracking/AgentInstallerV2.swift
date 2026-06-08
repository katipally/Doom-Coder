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
                let app = "/Applications/DoomCode.app/Contents/Resources/dc-hook"
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
        return "/Applications/DoomCode.app/Contents/Resources/dc-hook"
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
            case .copilotCLI: try installCopilotCLI()
            case .windsurf:   try installWindsurf()
            case .codexCLI:   try installCodexCLI()
            case .opencode:   try installOpenCode()
            }
            // opencode owns a JS plugin file (not a hooks JSON), so it uses a
            // file-content verification instead of the JSON-walk contract.
            if agent == .opencode {
                try verifyOpenCodeInstalled()
            } else {
                try verifyInstalled(agent: agent, at: path)
            }
            let postHash = sha256(of: path) ?? "?"
            let n = expectedEvents(for: agent).count
            logger.notice("installer op=install agent=\(agent.rawValue, privacy: .public) pre_hash=\(preHash, privacy: .public) post_hash=\(postHash, privacy: .public) events_asserted=\(n)/\(n) backup=\(backupPath ?? "-", privacy: .public) outcome=ok")
            NotificationCenter.default.post(name: .agentInstalledStateChanged, object: nil, userInfo: ["agent": agent.rawValue, "installed": true])
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
        // VS Code stores its hooks in a dedicated file we own outright + a
        // settings.json patch in every detected variant. Delete the file
        // and revert the chat.hookFilesLocations entry in one shot.
        if agent == .vscode {
            try? FileManager.default.removeItem(atPath: path)
            unpatchVSCodeSettings()
            logger.notice("installer op=uninstall agent=vscode outcome=ok")
            NotificationCenter.default.post(name: .agentInstalledStateChanged, object: nil, userInfo: ["agent": agent.rawValue, "installed": false])
            return .success(())
        }
        // Copilot CLI now owns ~/.copilot/hooks/doomcoder.json outright; just
        // delete the whole file rather than trying to strip dc-hook keys.
        if agent == .copilotCLI {
            try? FileManager.default.removeItem(atPath: path)
            logger.notice("installer op=uninstall agent=copilot_cli outcome=ok")
            NotificationCenter.default.post(name: .agentInstalledStateChanged, object: nil, userInfo: ["agent": agent.rawValue, "installed": false])
            return .success(())
        }
        // opencode owns ~/.config/opencode/plugin/doomcoder.js outright — delete it.
        if agent == .opencode {
            try? FileManager.default.removeItem(atPath: path)
            logger.notice("installer op=uninstall agent=opencode outcome=ok")
            NotificationCenter.default.post(name: .agentInstalledStateChanged, object: nil, userInfo: ["agent": agent.rawValue, "installed": false])
            return .success(())
        }
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
            let needsVer = agent == .cursor || agent == .copilotCLI
            try writeJSON(root, to: path, needsVersion: needsVer)
            try verifyUninstalled(at: path, agent: agent)
            let postHash = sha256(of: path) ?? "absent"
            logger.notice("installer op=uninstall agent=\(agent.rawValue, privacy: .public) pre_hash=\(preHash, privacy: .public) post_hash=\(postHash, privacy: .public) backup=\(backupPath ?? "-", privacy: .public) outcome=ok")
            NotificationCenter.default.post(name: .agentInstalledStateChanged, object: nil, userInfo: ["agent": agent.rawValue, "installed": false])
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
    /// Also removes any stale sibling backup files from previous Doom Coder versions.
    static func healAllPaths() {
        cleanAllSiblingBackups()
        var healed = 0
        var files = 0
        for agent in TrackedAgent.allCases {
            if isInstalled(agent) {
                files += 1
                if case .success = install(agent) { healed += 1 }
            }
        }
        logger.notice("heal op=paths healed=\(healed) files=\(files)")
    }

    /// Remove all `.doomcoder-backup-*` and `.doomcoder-backup` sibling files from known config directories.
    /// These were created by an older fallback code path and are no longer needed.
    static func cleanAllSiblingBackups() {
        let configFiles = [
            claudeSettingsPath(),
            cursorHooksPath(),
            windsurfHooksPath(),
            codexHooksPath(),
            codexConfigPath(),
            copilotCLIHooksPath(),
            vscodeCopilotHooksPath(),
        ]
        let fm = FileManager.default
        var removed = 0
        for configFile in configFiles {
            let dir = (configFile as NSString).deletingLastPathComponent
            let base = (configFile as NSString).lastPathComponent
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasPrefix(base + ".doomcoder-backup") {
                let full = (dir as NSString).appendingPathComponent(entry)
                try? fm.removeItem(atPath: full)
                removed += 1
            }
        }
        if removed > 0 {
            logger.notice("heal op=sibling_backup_cleanup removed=\(removed)")
        }
    }

    // MARK: - Detection

    static func isInstalled(_ agent: TrackedAgent) -> Bool {
        switch agent {
        case .copilotCLI:
            return fileContainsDcHookFor(agent: "copilot_cli", at: copilotCLIHooksPath())
        case .vscode:
            // VS Code now reads its own dedicated file under ~/.copilot/vscode-hooks/.
            // Detect by presence of the file with our vscode token.
            return fileContainsDcHookFor(agent: "vscode", at: vscodeCopilotHooksPath())
        case .claude:
            return fileContainsDcHookFor(agent: "claude", at: claudeSettingsPath())
        case .cursor:
            return fileContainsDcHookFor(agent: "cursor", at: cursorHooksPath())
        case .windsurf:
            return fileContainsDcHookFor(agent: "windsurf", at: windsurfHooksPath())
        case .codexCLI:
            return fileContainsDcHookFor(agent: "codex_cli", at: codexHooksPath())
        case .opencode:
            // Plain-JS plugin file we own; detect by our managed-file markers.
            guard let text = try? String(contentsOfFile: opencodePluginPath(), encoding: .utf8) else { return false }
            return text.contains("dc-hook") && text.contains("opencode")
        }
    }

    // MARK: - Config paths

    static func configPath(for agent: TrackedAgent, folder: URL? = nil) -> String {
        switch agent {
        case .claude:     return claudeSettingsPath()
        case .cursor:     return cursorHooksPath()
        case .vscode:     return vscodeCopilotHooksPath()
        case .windsurf:   return windsurfHooksPath()
        case .codexCLI:   return codexHooksPath()
        case .copilotCLI: return copilotCLIHooksPath()
        case .opencode:   return opencodePluginPath()
        }
    }

    static func claudeSettingsPath() -> String { NSHomeDirectory() + "/.claude/settings.json" }
    static func cursorHooksPath()   -> String { NSHomeDirectory() + "/.cursor/hooks.json" }
    static func windsurfHooksPath() -> String { NSHomeDirectory() + "/.codeium/windsurf/hooks.json" }
    static func codexHooksPath()    -> String { NSHomeDirectory() + "/.codex/hooks.json" }
    static func codexConfigPath()   -> String { NSHomeDirectory() + "/.codex/config.toml" }
    /// Global hooks file picked up by Copilot CLI (`copilot` binary) across
    /// every directory the user runs it from.
    static func copilotCLIHooksPath() -> String { NSHomeDirectory() + "/.copilot/hooks/doomcoder.json" }
    /// Dedicated VS Code Copilot Chat hooks file (absolute, used for disk I/O).
    static func vscodeCopilotHooksPath() -> String { NSHomeDirectory() + "/.copilot/vscode-hooks/doomcoder.json" }
    /// Directory portion of `vscodeCopilotHooksPath()` as a **literal tilde
    /// string** — VS Code's `chat.hookFilesLocations` silently rejects
    /// absolute paths; only relative and `~`-prefixed paths are honored.
    /// Use this exclusively when writing/reading the settings.json entry.
    static func vscodeCopilotHooksDir() -> String { "~/.copilot/vscode-hooks" }
    /// Absolute filesystem path for FileManager / ensureParentDir calls.
    static func vscodeCopilotHooksDirAbsolute() -> String { NSHomeDirectory() + "/.copilot/vscode-hooks" }
    /// Literal tilde path for the Copilot CLI hooks dir. We write this with
    /// `false` into VS Code's `chat.hookFilesLocations` to suppress the
    /// default-discovery double-fire (VS Code reads `~/.copilot/hooks` by
    /// default; if we let it, every CLI hook would fire twice).
    static func copilotCLIHooksDirLiteral() -> String { "~/.copilot/hooks" }

    /// opencode's global config directory. Honors `OPENCODE_CONFIG_DIR`, then
    /// `XDG_CONFIG_HOME`, else the XDG default (`~/.config/opencode`). This is
    /// the same resolution opencode itself uses, so our plugin lands where both
    /// the CLI/TUI and the desktop app will auto-load it.
    static func opencodeConfigDir() -> String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["OPENCODE_CONFIG_DIR"], !override.isEmpty { return override }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty { return xdg + "/opencode" }
        return NSHomeDirectory() + "/.config/opencode"
    }
    /// Absolute path to the Doom Coder opencode plugin file. opencode auto-loads
    /// any `*.js` under the `plugin/` subdirectory of its config dir.
    static func opencodePluginPath() -> String { opencodeConfigDir() + "/plugin/doomcoder.js" }

    // MARK: - Public verification

    /// Returns `.success` if hooks are correctly installed for `agent`,
    /// `.failure(VerifyError.integrityDrift(...))` with a concrete diff if
    /// any expected events are missing or any helper path is stale.
    ///
    /// - Parameter folder: Only meaningful for `.copilotCLI`, which has a
    ///   per-project config. For other agents the argument is ignored.
    static func verifyInstalled(_ agent: TrackedAgent, folder: URL? = nil) -> Result<Void, Error> {
        let path = configPath(for: agent, folder: folder)
        return verifyDetailed(agent: agent, at: path, folder: folder)
    }

    /// Verify hook installation for every agent. Returns a per-agent
    /// success/failure result, used by the Configure window's health badge.
    static func verifyAll() -> [TrackedAgent: Result<Void, Error>] {
        var out: [TrackedAgent: Result<Void, Error>] = [:]
        for agent in TrackedAgent.allCases where isInstalled(agent) {
            out[agent] = verifyInstalled(agent)
        }
        return out
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
        // VS Code Copilot Chat hooks live in their own file so they never
        // collide with CLI events. Discover paths via the `chat.hookFilesLocations`
        // settings.json setting, which we patch for every detected variant
        // (Stable, Insiders, VSCodium, Cursor, Windsurf).
        let path = vscodeCopilotHooksPath()
        try ensureParentDir(path)

        var root: [String: Any] = [:]
        var hooks: [String: Any] = [:]
        for event in vscodeEvents {
            let entry: [String: Any] = [
                "matcher": "*",
                "hooks": [
                    [
                        "type": "command",
                        "command": cmdFor("vscode", event)
                    ] as [String: Any]
                ]
            ]
            hooks[event] = [entry]
        }
        root["hooks"] = hooks
        try writeJSON(root, to: path, needsVersion: false)

        // Patch every enabled VS Code variant's settings.json to include the
        // hooks directory. Failures are non-fatal — the file write above is
        // the real installation; settings.json is just discovery wiring.
        patchVSCodeSettings()
    }

    private static func installWindsurf() throws {
        // Windsurf uses ~/.codeium/windsurf/hooks.json with a top-level "hooks" dict.
        // No version field required. Format: {"hooks": {"event": [{"command": "..."}]}}
        let path = windsurfHooksPath()
        try ensureParentDir(path)
        var root = readJSON(at: path) ?? [:]

        // Strip only Windsurf dc-hook entries (preserves any other hooks user may have)
        stripDcHookEntries(&root, agentToken: "windsurf")
        pruneEmptyContainers(&root)

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for event in windsurfEvents {
            let entry: [String: Any] = ["command": cmdFor("windsurf", event)]
            var arr = (hooks[event] as? [[String: Any]]) ?? []
            arr.append(entry)
            hooks[event] = arr
        }
        root["hooks"] = hooks
        // Windsurf does NOT require a version field — write without it
        try writeJSON(root, to: path, needsVersion: false)
    }

    /// Codex CLI uses `~/.codex/hooks.json` with a nested matcher format
    /// (same shape as Claude). Each event maps to an array of matcher groups,
    /// each containing `hooks: [{ type: "command", command: "..." }]`.
    /// Also requires `[features] codex_hooks = true` in `~/.codex/config.toml`.
    private static func installCodexCLI() throws {
        let path = codexHooksPath()
        try ensureParentDir(path)
        var root = readJSON(at: path) ?? [:]

        stripDcHookEntries(&root, agentToken: "codex_cli")
        pruneEmptyContainers(&root)

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for event in codexEvents {
            let hookEntry: [String: Any] = [
                "type": "command",
                "command": cmdFor("codex_cli", event)
            ]
            var matcherGroup: [String: Any] = ["hooks": [hookEntry]]
            // SessionStart: only fire for "startup" and "resume" sources, NOT
            // for "clear" (conversation reset). Per Codex hooks spec, the
            // `matcher` field is compared against the `source` field in the
            // SessionStart payload. Omitting matcher would fire on clear too.
            if event == "SessionStart" {
                matcherGroup["matcher"] = "startup|resume"
            }
            var arr = (hooks[event] as? [[String: Any]]) ?? []
            arr.append(matcherGroup)
            hooks[event] = arr
        }
        root["hooks"] = hooks
        try writeJSON(root, to: path, needsVersion: false)

        try ensureCodexFeatureFlag()
    }

    /// Ensure `[features] codex_hooks = true` is present in `~/.codex/config.toml`.
    /// Idempotent — preserves all other settings. Uses sentinel comments so
    /// uninstall can strip our managed block precisely.
    private static func ensureCodexFeatureFlag() throws {
        let path = codexConfigPath()
        try ensureParentDir(path)
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let beginMarker = "# doomcoder-managed:codex-features v1 BEGIN"
        let endMarker = "# doomcoder-managed:codex-features v1 END"

        // Already enabled outside our managed block? Don't touch.
        if !existing.contains(beginMarker) {
            let hasFlag = existing.range(
                of: #"(?m)^\s*codex_hooks\s*=\s*true"#,
                options: .regularExpression
            ) != nil
            if hasFlag { return }
        }

        // Strip any prior managed block (idempotency)
        var stripped = existing
        if let beginRange = stripped.range(of: beginMarker),
           let endRange = stripped.range(of: endMarker, range: beginRange.upperBound..<stripped.endIndex) {
            let blockEnd = stripped.index(endRange.upperBound, offsetBy: 0)
            // Also drop trailing newline after END marker if present
            var dropEnd = blockEnd
            if dropEnd < stripped.endIndex, stripped[dropEnd] == "\n" {
                dropEnd = stripped.index(after: dropEnd)
            }
            stripped.removeSubrange(beginRange.lowerBound..<dropEnd)
        }

        let needsLeadingNewline = !stripped.isEmpty && !stripped.hasSuffix("\n")
        let block = "\(needsLeadingNewline ? "\n" : "")\(beginMarker)\n[features]\ncodex_hooks = true\n\(endMarker)\n"
        let final = stripped + block

        if existing != final {
            backup(path)
            try final.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func installCopilotCLI() throws {
        // Global Copilot CLI hooks file — picked up automatically by every
        // `copilot` invocation regardless of working directory.
        let path = copilotCLIHooksPath()
        try ensureParentDir(path)

        let events = copilotCLIEvents
        var hooks: [String: Any] = [:]
        for event in events {
            hooks[event] = [[
                "type": "command",
                "bash": cmdFor("copilot_cli", event),
                "timeoutSec": 10
            ] as [String: Any]]
        }
        let root: [String: Any] = ["version": 1, "hooks": hooks]
        try writeJSON(root, to: path, needsVersion: true)
    }

    /// opencode integration: write a plain-JS plugin into the opencode config
    /// dir. The plugin (see `OpenCodePluginTemplate`) forwards a curated set of
    /// lifecycle events to dc-hook. No `opencode.json` edit is needed — opencode
    /// auto-loads every `*.js` under `plugin/`. Applies to the CLI/TUI and the
    /// desktop app alike.
    private static func installOpenCode() throws {
        let path = opencodePluginPath()
        try ensureParentDir(path)
        let js = OpenCodePluginTemplate.render(dcHookPath: helperBinaryPath())
        try js.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// File-content verification for the opencode plugin (replaces the JSON-walk
    /// contract the other agents use, since opencode owns a `.js` file).
    private static func verifyOpenCodeInstalled() throws {
        let path = opencodePluginPath()
        guard FileManager.default.fileExists(atPath: path) else { throw VerifyError.fileMissing }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw VerifyError.parseError }
        guard text.contains("dc-hook"), text.contains("opencode") else { throw VerifyError.unexpectedStructure }
        // The plugin spawns this exact binary — assert it exists and is runnable.
        let bin = helperBinaryPath()
        if bin.hasPrefix("/") && !FileManager.default.isExecutableFile(atPath: bin) {
            throw VerifyError.badHelperPath(bin)
        }
    }

    // MARK: - Hook command builder

    /// Complete event lists per agent — single source of truth.
    static let claudeEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "UserPromptExpansion",
        "PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch",
        "PermissionRequest", "PermissionDenied",
        "Notification", "Stop", "StopFailure",
        "SubagentStart", "SubagentStop",
        "TaskCreated", "TaskCompleted",
        "TeammateIdle",
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
        "beforeTabFileRead", "afterTabFileEdit",
        "workspaceOpen"
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
        "preToolUse", "postToolUse", "postToolUseFailure",
        "agentStop",
        "subagentStart", "subagentStop",
        "errorOccurred",
        "preCompact",
        "notification",
        "permissionRequest"
    ]

    // All 12 Windsurf Cascade hook events — snake_case, no version field required.
    static let windsurfEvents = [
        "pre_read_code", "post_read_code",
        "pre_write_code", "post_write_code",
        "pre_run_command", "post_run_command",
        "pre_mcp_tool_use", "post_mcp_tool_use",
        "pre_user_prompt",
        "post_cascade_response",
        "post_cascade_response_with_transcript",
        "post_setup_worktree"
    ]

    // OpenAI Codex CLI hook events (May 2026). Requires `codex_hooks = true`
    // feature flag in ~/.codex/config.toml.
    // OpenAI Codex CLI hook events (May 2026). Requires `codex_hooks = true`
    // feature flag in ~/.codex/config.toml.
    // Source: openai/codex codex-rs/app-server-protocol/src/protocol/v2/hook.rs
    static let codexEvents = [
        "SessionStart", "PreToolUse", "PermissionRequest",
        "PostToolUse", "UserPromptSubmit", "Stop",
        "PreCompact", "PostCompact"
    ]

    // opencode event tokens forwarded by our plugin (dotted bus/hook names).
    // Not written into a config file (opencode has no shell-command hooks) —
    // this list mirrors the plugin's allow-list and the normalizer phaseMap,
    // and is surfaced in logs / the agent detail pane.
    static let opencodeEvents = [
        "session.created", "session.idle", "session.error", "session.compacted",
        "session.deleted", "tool.execute.before", "tool.execute.after",
        "permission.asked", "permission.replied",
        "question.asked", "question.replied", "question.rejected",
        "file.edited"
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
    // our helper path (dc-hook) is a Doom Coder entry. Drop it. Prune up-tree.

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
        case .windsurf:   return windsurfEvents
        case .codexCLI:   return codexEvents
        case .opencode:   return opencodeEvents
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
        /// Integrity drift detected by a post-install verification.
        /// `missing` are expected events that are not mapped in the
        /// config; `wrongPath` are helper binary paths referenced in the
        /// config that no longer exist or aren't executable. `folder` is
        /// populated for per-folder Copilot CLI configs.
        case integrityDrift(missing: [String], wrongPath: [String], folder: URL?)

        var errorDescription: String? {
            switch self {
            case .fileMissing:
                return "Config file was not created — check that the parent directory exists and is writable."
            case .parseError:
                return "Config file contains invalid JSON — it may have been corrupted. Check the backup in ~/Library/Application Support/DoomCoder/backups/."
            case .missingEvent(let e):
                return "Hook event '\(e)' is missing from the config. Try uninstalling and reinstalling."
            case .badHelperPath(let p):
                return "dc-hook binary not found at '\(p)'. Try reinstalling Doom Coder from the DMG."
            case .residualDcHook:
                return "Some hook entries could not be removed. Open the config file manually to clean up."
            case .unexpectedStructure:
                return "Config file has an unexpected structure. It may have been edited by another tool."
            case .configPermissionDenied(let p):
                return "Cannot write to '\(p)' — check file permissions (chmod 644)."
            case .agentNotInstalled(let a):
                return "\(a.displayName) does not appear to be installed on this system."
            case .helperBinaryMissing:
                return "dc-hook binary not found in the app bundle. Try reinstalling DoomCode."
            case .integrityDrift(let missing, let wrongPath, let folder):
                var parts: [String] = []
                if let f = folder {
                    parts.append("Folder \(f.lastPathComponent):")
                }
                if !missing.isEmpty {
                    parts.append("missing events [\(missing.joined(separator: ", "))]")
                }
                if !wrongPath.isEmpty {
                    parts.append("stale helper path [\(wrongPath.joined(separator: ", "))]")
                }
                if parts.isEmpty { parts.append("hook config drifted from expected layout") }
                return parts.joined(separator: " ")
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
                return "Reinstall Doom Coder from the latest release."
            case .residualDcHook:
                return "Use 'Show Config' to manually inspect the file."
            case .configPermissionDenied:
                return "Fix file permissions in Terminal, then retry."
            case .agentNotInstalled:
                return nil
            case .integrityDrift(_, _, let folder):
                return folder == nil
                    ? "Use Repair to reinstall the hook config."
                    : "Use Repair to reinstall hooks for this folder."
            }
        }
    }

    /// Non-throwing detailed verification that collects *every* mismatch
    /// (all missing events + all stale helper paths) and surfaces them as
    /// a single `integrityDrift` error so the UI can show the user a
    /// precise diff instead of a vague external-modification banner.
    private static func verifyDetailed(agent: TrackedAgent, at path: String, folder: URL?) -> Result<Void, Error> {
        // opencode owns a JS plugin file, not a hooks JSON — use the file-content
        // contract instead of the JSON walk (which would fail to parse `.js`).
        if agent == .opencode {
            do { try verifyOpenCodeInstalled(); return .success(()) }
            catch { return .failure(error) }
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(VerifyError.fileMissing)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(VerifyError.parseError)
        }
        let token = dcHookAgentToken(agent)
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
        var missing: [String] = []
        for event in expectedEvents(for: agent) where !seenEvents.contains(event) {
            missing.append(event)
        }
        var wrongPath: [String] = []
        for bin in helperPaths where bin.hasPrefix("/") {
            if !FileManager.default.isExecutableFile(atPath: bin) {
                wrongPath.append(bin)
            }
        }
        if missing.isEmpty && wrongPath.isEmpty { return .success(()) }
        return .failure(VerifyError.integrityDrift(missing: missing, wrongPath: wrongPath, folder: folder))
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
        case .windsurf:   return "windsurf"
        case .codexCLI:   return "codex_cli"
        case .opencode:   return "opencode"
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
        let backupDir = AgentSupportDir.url.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
        let dst = backupDir.appendingPathComponent(name).path
        do {
            // Overwrite any existing backup — keep only one per config file.
            if FileManager.default.fileExists(atPath: dst) {
                try FileManager.default.removeItem(atPath: dst)
            }
            try FileManager.default.copyItem(atPath: path, toPath: dst)
            return dst
        } catch {
            // Secondary fallback — single sibling backup next to the file (no timestamp).
            let sibling = "\(path).doomcoder-backup"
            try? FileManager.default.removeItem(atPath: sibling)
            try? FileManager.default.copyItem(atPath: path, toPath: sibling)
            return FileManager.default.fileExists(atPath: sibling) ? sibling : nil
        }
    }

    // MARK: - VS Code variants (settings.json patch)

    /// Default settings.json paths for every host that ships VS Code Copilot
    /// Chat. Order matters only for log readability.
    static func vscodeVariantSettingsPaths() -> [String] {
        let base = NSHomeDirectory() + "/Library/Application Support/"
        return [
            base + "Code/User/settings.json",
            base + "Code - Insiders/User/settings.json",
            base + "VSCodium/User/settings.json",
            base + "Cursor/User/settings.json",
            base + "Windsurf/User/settings.json",
        ]
    }

    /// Variants the user actually wants us to touch. Defaults to every
    /// detected variant; persisted under `doomcoder.vscode.variants.enabled`.
    static func vscodeEnabledVariantPaths() -> [String] {
        let key = "doomcoder.vscode.variants.enabled"
        let all = vscodeVariantSettingsPaths()
        if let saved = UserDefaults.standard.array(forKey: key) as? [String] {
            return saved.filter { all.contains($0) }
        }
        return all.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func setVSCodeEnabledVariants(_ paths: [String]) {
        UserDefaults.standard.set(paths, forKey: "doomcoder.vscode.variants.enabled")
    }

    /// Merge `~/.copilot/vscode-hooks` into every enabled variant's
    /// `chat.hookFilesLocations` and simultaneously suppress the default
    /// discovery of `~/.copilot/hooks` (the Copilot CLI dir) so VS Code
    /// doesn't fire every CLI hook twice. Idempotent and tolerant of
    /// JSONC (line comments, block comments, trailing commas).
    static func patchVSCodeSettings() {
        let entry = vscodeCopilotHooksDir()
        let cliDir = copilotCLIHooksDirLiteral()
        for path in vscodeEnabledVariantPaths() where FileManager.default.fileExists(atPath: path) {
            do {
                guard var root = readJSONC(at: path) else { continue }
                _ = backup(path)
                var locs = (root["chat.hookFilesLocations"] as? [String: Any]) ?? [:]
                locs[entry] = true
                // Only set the CLI-dir suppressor if the user hasn't explicitly
                // opted to enable it. Preserve a user-set `true` exactly as-is.
                if let existing = locs[cliDir] as? Bool, existing == true {
                    // User wants the CLI dir — leave alone.
                } else {
                    locs[cliDir] = false
                }
                root["chat.hookFilesLocations"] = locs
                try writeJSON(root, to: path, needsVersion: false)
                logger.notice("vscode settings patched at=\(path, privacy: .public)")
            } catch {
                logger.error("vscode settings patch failed at=\(path, privacy: .public) err=\(String(describing: error), privacy: .public)")
            }
        }
    }

    static func unpatchVSCodeSettings() {
        let entry = vscodeCopilotHooksDir()
        let cliDir = copilotCLIHooksDirLiteral()
        for path in vscodeVariantSettingsPaths() where FileManager.default.fileExists(atPath: path) {
            do {
                guard var root = readJSONC(at: path) else { continue }
                guard var locs = root["chat.hookFilesLocations"] as? [String: Any] else { continue }
                let hasEntry = locs[entry] != nil
                // Only reverse the CLI-dir suppressor if WE set it (value is exactly false).
                let hasOurSuppressor: Bool = {
                    if let v = locs[cliDir] as? Bool, v == false { return true }
                    return false
                }()
                guard hasEntry || hasOurSuppressor else { continue }
                _ = backup(path)
                if hasEntry { locs.removeValue(forKey: entry) }
                if hasOurSuppressor { locs.removeValue(forKey: cliDir) }
                if locs.isEmpty {
                    root.removeValue(forKey: "chat.hookFilesLocations")
                } else {
                    root["chat.hookFilesLocations"] = locs
                }
                try writeJSON(root, to: path, needsVersion: false)
                logger.notice("vscode settings unpatched at=\(path, privacy: .public)")
            } catch {
                logger.error("vscode settings unpatch failed at=\(path, privacy: .public) err=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// JSONC-tolerant read. Strips `//` line comments, `/* */` block
    /// comments, and trailing commas before handing to JSONSerialization.
    /// Preserves string literals so a `//` inside a string is not stripped.
    private static func readJSONC(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = String(data: data, encoding: .utf8) else { return [:] }
        let stripped = stripJSONC(raw)
        guard let cleanData = stripped.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: cleanData) else { return nil }
        return (any as? [String: Any]) ?? [:]
    }

    static func stripJSONC(_ src: String) -> String {
        var out = ""
        out.reserveCapacity(src.count)
        var inString = false
        var stringQuote: Character = "\""
        var prevWasBackslash = false
        var i = src.startIndex
        while i < src.endIndex {
            let c = src[i]
            if inString {
                out.append(c)
                if c == "\\" && !prevWasBackslash {
                    prevWasBackslash = true
                } else {
                    if c == stringQuote && !prevWasBackslash {
                        inString = false
                    }
                    prevWasBackslash = false
                }
                i = src.index(after: i)
                continue
            }
            if c == "\"" {
                inString = true
                stringQuote = c
                out.append(c)
                i = src.index(after: i)
                continue
            }
            // Line comment
            if c == "/", src.index(after: i) < src.endIndex, src[src.index(after: i)] == "/" {
                while i < src.endIndex && src[i] != "\n" { i = src.index(after: i) }
                continue
            }
            // Block comment
            if c == "/", src.index(after: i) < src.endIndex, src[src.index(after: i)] == "*" {
                i = src.index(i, offsetBy: 2)
                while i < src.endIndex {
                    if src[i] == "*", src.index(after: i) < src.endIndex, src[src.index(after: i)] == "/" {
                        i = src.index(i, offsetBy: 2)
                        break
                    }
                    i = src.index(after: i)
                }
                continue
            }
            out.append(c)
            i = src.index(after: i)
        }
        // Strip trailing commas: `,` followed by optional whitespace then `}` or `]`.
        var result = ""
        result.reserveCapacity(out.count)
        var j = out.startIndex
        while j < out.endIndex {
            let c = out[j]
            if c == "," {
                var k = out.index(after: j)
                while k < out.endIndex, out[k].isWhitespace { k = out.index(after: k) }
                if k < out.endIndex, out[k] == "}" || out[k] == "]" {
                    j = k
                    continue
                }
            }
            result.append(c)
            j = out.index(after: j)
        }
        return result
    }

    // MARK: - Errors

    enum InstallerError: LocalizedError {
        case unknown
        var errorDescription: String? { return "Unknown installer error." }
    }
}
