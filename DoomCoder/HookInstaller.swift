import Foundation

// MARK: - HookInstaller
//
// Writes, verifies, and uninstalls shell-hook wiring for each Tier 1 agent.
// Central design goals:
//   1. Never clobber the user's existing hooks — we merge, we don't overwrite.
//   2. Every install first writes a `*.doomcoder-backup-<timestamp>.json` of the
//      original file, so "Restore backup" always works even across upgrades.
//   3. Our additions are tagged with a sentinel string `doomcoder-managed`
//      (both as a JSON key and in the command itself) so we can detect drift,
//      remove cleanly, and re-install on upgrade.
//   4. Install is idempotent — running it twice produces the same output.
//
// The hook command we write points at `~/.doomcoder/hook.sh`, which is deployed
// by HookRuntime on first app launch. It takes two args: <agent-id> <event-name>.

@MainActor
final class HookInstaller {

    // MARK: - Types

    enum Agent: String, CaseIterable, Identifiable {
        case claudeCode = "claude-code"
        case copilotCLI = "copilot-cli"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .copilotCLI: return "Copilot CLI"
            }
        }

        var summary: String {
            switch self {
            case .claudeCode:
                return "We add hooks to your Claude settings so it pings DoomCoder when it starts, finishes, or needs you. Claude never sees this — zero tokens, zero effect on your sessions."
            case .copilotCLI:
                return "We register native Copilot CLI hooks (April 2026 format) under ~/.copilot/hooks/hooks.json so it pings DoomCoder when it starts, waits on you, or finishes. Zero tokens, zero effect on your sessions."
            }
        }
    }

    enum Status: Equatable {
        case notInstalled
        case installed(configPath: String)
        case partial(configPath: String, reason: String)
        case missingHookScript

        var isInstalled: Bool { if case .installed = self { return true } else { return false } }
        var label: String {
            switch self {
            case .notInstalled:      return "Not set up"
            case .installed:         return "Connected"
            case .partial:           return "Partial"
            case .missingHookScript: return "Hook runtime missing"
            }
        }
    }

    enum InstallError: LocalizedError {
        case hookScriptMissing
        case readFailed(String, Error)
        case writeFailed(String, Error)
        case backupFailed(String, Error)
        case parseError(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .hookScriptMissing:            return "DoomCoder's hook runner script has not been deployed yet. Please restart DoomCoder and try again."
            case .readFailed(let p, let e):     return "Couldn't read \(p): \(e.localizedDescription)"
            case .writeFailed(let p, let e):    return "Couldn't write \(p): \(e.localizedDescription)"
            case .backupFailed(let p, let e):   return "Couldn't back up \(p): \(e.localizedDescription)"
            case .parseError(let p):            return "\(p) isn't valid JSON — refusing to edit. Please open the file and fix the syntax, or [Use our version] to replace it with a clean DoomCoder-managed file."
            case .unsupported(let msg):         return msg
            }
        }
    }

    // MARK: - Constants

    // Marker baked into every managed entry so we can identify + remove cleanly.
    static let marker = "doomcoder-managed"

    // MARK: - Public API

    static func status(for agent: Agent) -> Status {
        guard HookRuntime.isDeployed else { return .missingHookScript }
        switch agent {
        case .claudeCode: return claudeCodeStatus()
        case .copilotCLI: return copilotCLIStatus()
        }
    }

    @discardableResult
    static func install(_ agent: Agent) throws -> String {
        guard HookRuntime.isDeployed else { throw InstallError.hookScriptMissing }
        switch agent {
        case .claudeCode: return try installClaudeCode()
        case .copilotCLI: return try installCopilotCLI()
        }
    }

    @discardableResult
    static func uninstall(_ agent: Agent) throws -> String {
        switch agent {
        case .claudeCode: return try uninstallClaudeCode()
        case .copilotCLI: return try uninstallCopilotCLI()
        }
    }

    // Path to the config we manage for this agent (even if not yet installed).
    static func configPath(for agent: Agent) -> String {
        switch agent {
        case .claudeCode: return claudeSettingsURL.path
        case .copilotCLI: return copilotHooksJSONURL.path
        }
    }

    // Most-recent backup file (if any) for this agent.
    static func latestBackup(for agent: Agent) -> URL? {
        let target = URL(fileURLWithPath: configPath(for: agent))
        let dir    = target.deletingLastPathComponent()
        let prefix = target.lastPathComponent + ".doomcoder-backup-"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let candidates = entries
            .filter { $0.hasPrefix(prefix) }
            .sorted()
        guard let latest = candidates.last else { return nil }
        return dir.appendingPathComponent(latest)
    }

    @discardableResult
    static func restoreLatestBackup(for agent: Agent) throws -> String {
        guard let backup = latestBackup(for: agent) else {
            throw InstallError.unsupported("No backup file was found for \(agent.displayName). DoomCoder only creates backups when it installs or edits your config.")
        }
        let target = URL(fileURLWithPath: configPath(for: agent))
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            do { try fm.removeItem(at: target) } catch {
                throw InstallError.writeFailed(target.path, error)
            }
        }
        do { try fm.copyItem(at: backup, to: target) } catch {
            throw InstallError.writeFailed(target.path, error)
        }
        return target.path
    }

    // MARK: - Paths

    private static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    private static var copilotExtensionDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/extensions/doomcoder")
    }

    private static var copilotExtensionFile: URL {
        copilotExtensionDir.appendingPathComponent("hook.sh")
    }

    // April 2026 Copilot CLI native hook configuration. Events are declared
    // in ~/.copilot/hooks/hooks.json and invoke bash commands for:
    //   sessionStart, sessionEnd, preToolUse, postToolUse,
    //   userPromptSubmitted, errorOccurred
    private static var copilotHooksJSONURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks/hooks.json")
    }

    // MARK: - Claude Code
    //
    // Claude Code supports a user-level `settings.json` file with a `hooks` object keyed
    // by event name. Each value is an array of matchers with a `hooks` array inside.
    // Minimal example:
    //   { "hooks": { "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "…" }] }] } }
    //
    // We install our command into eight events. The command format is:
    //   sh ~/.doomcoder/hook.sh claude-code <event-name>  # doomcoder-managed
    //
    // On uninstall, we remove entries containing the marker and leave everything else.

    private static let claudeEvents = [
        "SessionStart", "SessionEnd",
        "PreToolUse", "PostToolUse",
        "Notification", "UserPromptSubmit",
        "Stop", "SubagentStop"
    ]

    private static func claudeCommand(event: String) -> String {
        "sh \(HookRuntime.hookScriptURL.path) claude-code \(event) # \(marker)"
    }

    private static func claudeCodeStatus() -> Status {
        let path = claudeSettingsURL.path
        guard FileManager.default.fileExists(atPath: path) else { return .notInstalled }
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .partial(configPath: path, reason: "settings.json exists but isn't valid JSON")
        }
        let hooks = (obj["hooks"] as? [String: Any]) ?? [:]
        var installedCount = 0
        for event in claudeEvents {
            if let matchers = hooks[event] as? [[String: Any]],
               matchers.contains(where: { matcher in
                   guard let innerHooks = matcher["hooks"] as? [[String: Any]] else { return false }
                   return innerHooks.contains { (($0["command"] as? String) ?? "").contains(marker) }
               }) {
                installedCount += 1
            }
        }
        if installedCount == 0                       { return .notInstalled }
        if installedCount == claudeEvents.count      { return .installed(configPath: path) }
        return .partial(configPath: path, reason: "\(installedCount) of \(claudeEvents.count) hooks present — re-run Setup to fix")
    }

    @discardableResult
    private static func installClaudeCode() throws -> String {
        let url = claudeSettingsURL
        try ensureParentDirectory(for: url)

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            try backup(fileAt: url)
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                throw InstallError.readFailed(url.path, error)
            }
            if data.isEmpty {
                root = [:]
            } else if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = parsed
            } else {
                throw InstallError.parseError(url.path)
            }
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for event in claudeEvents {
            var matchers = (hooks[event] as? [[String: Any]]) ?? []

            // Strip any existing managed entries so re-install is idempotent.
            matchers = matchers.compactMap { m -> [String: Any]? in
                var mCopy = m
                var inner = (mCopy["hooks"] as? [[String: Any]]) ?? []
                inner.removeAll { (($0["command"] as? String) ?? "").contains(marker) }
                mCopy["hooks"] = inner
                // If we stripped everything and matcher is now empty, drop it.
                if inner.isEmpty { return nil }
                return mCopy
            }

            // Append our entry as a fresh matcher so we don't disturb user entries.
            let ourEntry: [String: Any] = [
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": claudeCommand(event: event),
                    marker: true
                ]]
            ]
            matchers.append(ourEntry)
            hooks[event] = matchers
        }
        root["hooks"] = hooks

        try writeJSONPretty(root, to: url)
        return url.path
    }

    @discardableResult
    private static func uninstallClaudeCode() throws -> String {
        let url = claudeSettingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return url.path }

        try backup(fileAt: url)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw InstallError.readFailed(url.path, error)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.parseError(url.path)
        }
        var root = parsed
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        for event in claudeEvents {
            guard var matchers = hooks[event] as? [[String: Any]] else { continue }
            matchers = matchers.compactMap { m -> [String: Any]? in
                var mCopy = m
                var inner = (mCopy["hooks"] as? [[String: Any]]) ?? []
                inner.removeAll { (($0["command"] as? String) ?? "").contains(marker) }
                if inner.isEmpty { return nil }
                mCopy["hooks"] = inner
                return mCopy
            }
            if matchers.isEmpty { hooks.removeValue(forKey: event) }
            else                { hooks[event] = matchers }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else             { root["hooks"] = hooks }

        try writeJSONPretty(root, to: url)
        return url.path
    }

    // MARK: - Copilot CLI
    //
    // April 2026 Copilot CLI configuration lives in `~/.copilot/hooks/hooks.json`.
    // Each event key maps to an array of command entries:
    //   { "sessionStart": [{ "type": "command", "bash": "~/.doomcoder/hook.sh copilot-cli sessionStart" }], … }
    //
    // We install six events. On `.partial` we offer to re-run Setup.
    //
    // Config is reloaded automatically by Copilot CLI on session start, so there's
    // no restart step for the user — unlike Cursor's MCP, which needs a Cmd+Q.
    //
    // Legacy (pre-April-2026) Copilot CLI used
    // `~/.copilot/extensions/doomcoder/hook.sh`. If we find it, we quietly remove
    // it on next install so users upgrading from v1.3 end up with exactly one
    // mechanism. The file is backed up first.

    private static let copilotEvents = [
        "sessionStart", "sessionEnd",
        "preToolUse", "postToolUse",
        "userPromptSubmitted", "errorOccurred"
    ]

    private static func copilotCommand(event: String) -> String {
        "sh \(HookRuntime.hookScriptURL.path) copilot-cli \(event) # \(marker)"
    }

    private static func copilotCLIStatus() -> Status {
        let url = copilotHooksJSONURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            // If only the legacy shim exists, report partial so Setup lights up.
            if FileManager.default.fileExists(atPath: copilotExtensionFile.path) {
                return .partial(configPath: copilotExtensionFile.path,
                                reason: "Legacy extension shim present — Setup will upgrade you to the April 2026 hooks.json format")
            }
            return .notInstalled
        }
        guard let data = try? Data(contentsOf: url),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .partial(configPath: url.path, reason: "hooks.json exists but isn't valid JSON")
        }
        var installed = 0
        for event in copilotEvents {
            if let arr = obj[event] as? [[String: Any]],
               arr.contains(where: { (($0["bash"] as? String) ?? "").contains(marker) }) {
                installed += 1
            }
        }
        if installed == 0                    { return .notInstalled }
        if installed == copilotEvents.count  { return .installed(configPath: url.path) }
        return .partial(configPath: url.path,
                        reason: "\(installed) of \(copilotEvents.count) hooks present — re-run Setup to fix")
    }

    @discardableResult
    private static func installCopilotCLI() throws -> String {
        // 1. Clean up legacy extension shim if it exists. We back it up first.
        let legacy = copilotExtensionFile
        if FileManager.default.fileExists(atPath: legacy.path) {
            // Only remove shims that we ourselves installed (marker match).
            if let old = try? String(contentsOf: legacy, encoding: .utf8),
               old.contains(marker) {
                try? backup(fileAt: legacy)
                try? FileManager.default.removeItem(at: legacy)
            }
        }

        // 2. Merge into hooks.json (or create).
        let url = copilotHooksJSONURL
        try ensureParentDirectory(for: url)
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            try backup(fileAt: url)
            let data: Data
            do { data = try Data(contentsOf: url) } catch {
                throw InstallError.readFailed(url.path, error)
            }
            if data.isEmpty {
                root = [:]
            } else if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = parsed
            } else {
                throw InstallError.parseError(url.path)
            }
        }

        for event in copilotEvents {
            var entries = (root[event] as? [[String: Any]]) ?? []
            entries.removeAll { (($0["bash"] as? String) ?? "").contains(marker) }
            entries.append([
                "type": "command",
                "bash": copilotCommand(event: event),
                marker: true
            ])
            root[event] = entries
        }

        try writeJSONPretty(root, to: url)
        return url.path
    }

    @discardableResult
    private static func uninstallCopilotCLI() throws -> String {
        let url = copilotHooksJSONURL
        // Also clean up any remaining legacy shim.
        let legacy = copilotExtensionFile
        if FileManager.default.fileExists(atPath: legacy.path),
           let old = try? String(contentsOf: legacy, encoding: .utf8),
           old.contains(marker) {
            try? backup(fileAt: legacy)
            try? FileManager.default.removeItem(at: legacy)
        }

        guard FileManager.default.fileExists(atPath: url.path) else { return url.path }
        try backup(fileAt: url)
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw InstallError.readFailed(url.path, error)
        }
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallError.parseError(url.path)
        }
        for event in copilotEvents {
            guard var entries = root[event] as? [[String: Any]] else { continue }
            entries.removeAll { (($0["bash"] as? String) ?? "").contains(marker) }
            if entries.isEmpty { root.removeValue(forKey: event) }
            else               { root[event] = entries }
        }
        try writeJSONPretty(root, to: url)
        return url.path
    }

    // MARK: - JSON/file helpers

    private static func ensureParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
            catch { throw InstallError.writeFailed(parent.path, error) }
        }
    }

    private static func backup(fileAt url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let stamp = Int(Date.now.timeIntervalSince1970)
        let dst = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".doomcoder-backup-\(stamp)")
        do { try fm.copyItem(at: url, to: dst) } catch {
            throw InstallError.backupFailed(url.path, error)
        }
    }

    private static func writeJSONPretty(_ obj: Any, to url: URL) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            throw InstallError.writeFailed(url.path, error)
        }
    }
}
