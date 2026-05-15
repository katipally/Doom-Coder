import Foundation
import OSLog

// Detects v1.8.5 broken hook configs (entries with x-doomcoder tag or wrong
// schema) and prompts user to migrate to v2.
enum MigrationManager {
    private static let logger = Logger(subsystem: "com.doomcoder", category: "migration")
    private static let migratedKey = "doomcoder.migration.v1_to_v2.done"
    private static let migratedHookShKey = "doomcoder.migration.hooksh.done"
    private static let migratedVSCodeFullEventsKey = "doomcoder.migration.vscode_full_events.done"

    /// Check if migration is needed. Returns list of affected agents.
    static func checkNeeded() -> [TrackedAgent] {
        if UserDefaults.standard.bool(forKey: migratedKey) { return [] }

        var affected: [TrackedAgent] = []

        // Check Claude settings for old x-doomcoder tags
        if hasLegacyEntries(at: AgentInstallerV2.claudeSettingsPath()) {
            affected.append(.claude)
        }

        // If vscode entries are still in the old shared Claude settings file,
        // migration is needed to move them to the new ~/.copilot/hooks/hooks.json.
        if AgentInstallerV2.fileContainsDcHookFor(agent: "vscode", at: AgentInstallerV2.claudeSettingsPath())
            && !affected.contains(.vscode) {
            affected.append(.vscode)
        }

        // Check Cursor for old x-doomcoder tags or missing version
        if hasLegacyEntries(at: AgentInstallerV2.cursorHooksPath()) {
            affected.append(.cursor)
        }

        return affected
    }

    /// Returns true if any Copilot CLI folder has an old hook.sh script,
    /// or if the user-level ~/.copilot/hooks/hooks.json still contains
    /// top-level camelCase hook.sh references from the pre-dc-hook era.
    static func needsHookShMigration() -> Bool {
        guard !UserDefaults.standard.bool(forKey: migratedHookShKey) else { return false }
        let hasPerFolder = CopilotCLIFolderManager.folders.contains { folder in
            let hookSh = folder.appendingPathComponent(".github/hooks/hook.sh").path
            return FileManager.default.fileExists(atPath: hookSh)
        }
        if hasPerFolder { return true }
        // Also detect old top-level hook.sh entries in the user-level file.
        return userLevelFileHasHookShEntries()
    }

    private static func userLevelFileHasHookShEntries() -> Bool {
        let path = AgentInstallerV2.copilotUserHooksPath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        // Check top-level camelCase keys for hook.sh references.
        for (_, value) in root {
            if let arr = value as? [[String: Any]] {
                for obj in arr {
                    let cmd = (obj["bash"] as? String) ?? (obj["command"] as? String) ?? ""
                    if cmd.contains("hook.sh") { return true }
                }
            }
        }
        return false
    }

    /// Remove legacy hook.sh scripts from registered Copilot CLI folders
    /// and strip old hook.sh references from the user-level hooks file.
    static func migrateHookSh() {
        for folder in CopilotCLIFolderManager.folders {
            let hookSh = folder.appendingPathComponent(".github/hooks/hook.sh").path
            if FileManager.default.fileExists(atPath: hookSh) {
                AgentInstallerV2.backup(hookSh)
                try? FileManager.default.removeItem(atPath: hookSh)
            }
        }
        // Strip hook.sh references from the user-level file by reinstalling
        // both VS Code and Copilot CLI hooks (install calls stripHookShEntries).
        let userPath = AgentInstallerV2.copilotUserHooksPath()
        if FileManager.default.fileExists(atPath: userPath) {
            if AgentInstallerV2.isInstalled(.vscode) {
                _ = AgentInstallerV2.install(.vscode)
            }
            if AgentInstallerV2.isInstalledCopilotCLIUserLevel() {
                _ = AgentInstallerV2.install(.copilotCLI)
            }
        }
        // UserDefaults.set() posts NSUserDefaultsDidChangeNotification which is
        // observed by @MainActor components — must be delivered on the main thread.
        DispatchQueue.main.async {
            UserDefaults.standard.set(true, forKey: migratedHookShKey)
            logger.info("hook.sh migration complete")
        }
    }

    /// Run migration: backup old configs, strip legacy entries, install v2 hooks.
    static func migrate(agents: [TrackedAgent]) {
        logger.info("Migrating \(agents.map(\.rawValue).joined(separator: ", "), privacy: .public)")

        for agent in agents {
            switch agent {
            case .claude:
                let path = AgentInstallerV2.claudeSettingsPath()
                AgentInstallerV2.backup(path)
                stripLegacy(at: path)
            case .vscode:
                // Re-install at the new path; installVSCode() also strips the old shared path.
                _ = AgentInstallerV2.install(.vscode)
                continue
            case .cursor:
                let path = AgentInstallerV2.cursorHooksPath()
                AgentInstallerV2.backup(path)
                stripLegacy(at: path)
            case .copilotCLI:
                // Per-folder: strip from each registered folder
                for folder in CopilotCLIFolderManager.folders {
                    let hooksFile = folder.appendingPathComponent(".github/hooks/doomcoder.json").path
                    AgentInstallerV2.backup(hooksFile)
                    stripLegacy(at: hooksFile)
                }
            case .windsurf, .codexCLI:
                break
            }

            // Re-install with correct v2 schema
            if agent == .copilotCLI {
                for folder in CopilotCLIFolderManager.folders {
                    _ = AgentInstallerV2.install(.copilotCLI, folder: folder)
                }
            } else if agent != .vscode {
                _ = AgentInstallerV2.install(agent)
            }
        }

        // UserDefaults.set() must be called on the main thread (posts NSNotification).
        DispatchQueue.main.async {
            UserDefaults.standard.set(true, forKey: migratedKey)
            logger.info("Migration complete")
        }
    }

    /// Returns true if the VS Code hook file has fewer events than the current full set,
    /// meaning it was installed before we expanded to all 29 Claude Code events.
    static func needsVSCodeFullEventsMigration() -> Bool {
        guard !UserDefaults.standard.bool(forKey: migratedVSCodeFullEventsKey) else { return false }
        let path = AgentInstallerV2.copilotUserHooksPath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        // If any new event is missing, we need to re-install.
        return AgentInstallerV2.vscodeEvents.contains { !text.contains($0) }
    }

    /// Re-install VS Code hooks with the full 29-event set, then mark done.
    static func migrateVSCodeFullEvents() {
        if AgentInstallerV2.isInstalled(.vscode) {
            _ = AgentInstallerV2.install(.vscode)
        }
        DispatchQueue.main.async {
            UserDefaults.standard.set(true, forKey: migratedVSCodeFullEventsKey)
            logger.info("VS Code full-events migration complete")
        }
    }

    static func markDone() {
        UserDefaults.standard.set(true, forKey: migratedKey)
    }

    // MARK: - Private

    private static func hasLegacyEntries(at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text.contains("x-doomcoder")
    }

    private static func stripLegacy(at path: String) {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        // Strip all x-doomcoder tagged entries AND dc-hook entries
        AgentInstallerV2.stripDcHookEntries(&root)
        stripXDoomcoderEntries(&root)
        AgentInstallerV2.pruneEmptyContainers(&root)

        if let output = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? output.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private static func stripXDoomcoderEntries(_ node: inout [String: Any]) {
        for (key, value) in node {
            if var arr = value as? [[String: Any]] {
                arr.removeAll { ($0["x-doomcoder"] as? String) != nil }
                if arr.isEmpty { node.removeValue(forKey: key) }
                else { node[key] = arr }
            } else if var dict = value as? [String: Any] {
                if dict["x-doomcoder"] != nil {
                    node.removeValue(forKey: key)
                } else {
                    stripXDoomcoderEntries(&dict)
                    node[key] = dict
                }
            }
        }
    }
}
