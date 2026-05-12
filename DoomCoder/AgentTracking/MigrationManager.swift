import Foundation
import Security
import OSLog

// Detects v1.8.5 broken hook configs (entries with x-doomcoder tag or wrong
// schema) and prompts user to migrate to v2.
enum MigrationManager {
    private static let logger = Logger(subsystem: "com.doomcoder", category: "migration")
    private static let migratedKey = "doomcoder.migration.v1_to_v2.done"

    /// Check if migration is needed. Returns list of affected agents.
    static func checkNeeded() -> [TrackedAgent] {
        if UserDefaults.standard.bool(forKey: migratedKey) { return [] }

        var affected: [TrackedAgent] = []

        // Check Claude settings for old x-doomcoder tags
        if hasLegacyEntries(at: AgentInstallerV2.claudeSettingsPath()) {
            affected.append(.claude)
            affected.append(.vscode) // shares same file
        }

        // Check Cursor for old x-doomcoder tags or missing version
        if hasLegacyEntries(at: AgentInstallerV2.cursorHooksPath()) {
            affected.append(.cursor)
        }

        // Check old VSCode path (v1.8.5 wrote to wrong location)
        let oldVSCodePath = NSHomeDirectory() + "/.copilot/hooks/hooks.json"
        if hasLegacyEntries(at: oldVSCodePath) && !affected.contains(.vscode) {
            affected.append(.vscode)
        }

        return affected
    }

    /// Run migration: backup old configs, strip legacy entries, install v2 hooks.
    static func migrate(agents: [TrackedAgent]) {
        logger.info("Migrating \(agents.map(\.rawValue).joined(separator: ", "), privacy: .public)")

        for agent in agents {
            switch agent {
            case .claude, .vscode:
                // Both share ~/.claude/settings.json — handle once
                let path = AgentInstallerV2.claudeSettingsPath()
                AgentInstallerV2.backup(path)
                stripLegacy(at: path)
            case .cursor:
                let path = AgentInstallerV2.cursorHooksPath()
                AgentInstallerV2.backup(path)
                stripLegacy(at: path)
            case .copilotCLI:
                // Per-folder: strip from each registered folder
                for folder in CopilotCLIFolderManager.folders {
                    let hooksFile = folder.appendingPathComponent("hooks.json").path
                    AgentInstallerV2.backup(hooksFile)
                    stripLegacy(at: hooksFile)
                }
            case .windsurf:
                // New agent — no v1 legacy format exists, nothing to strip
                break
            case .codexCLI:
                // New agent — no v1 legacy format exists, nothing to strip
                break
            }

            // Re-install with correct v2 schema
            if agent == .copilotCLI {
                for folder in CopilotCLIFolderManager.folders {
                    _ = AgentInstallerV2.install(.copilotCLI, folder: folder)
                }
            } else {
                _ = AgentInstallerV2.install(agent)
            }
        }

        // Also clean up old VSCode hooks at wrong path
        let oldVSCodePath = NSHomeDirectory() + "/.copilot/hooks/hooks.json"
        if FileManager.default.fileExists(atPath: oldVSCodePath) {
            AgentInstallerV2.backup(oldVSCodePath)
            stripLegacy(at: oldVSCodePath)
        }

        UserDefaults.standard.set(true, forKey: migratedKey)
        logger.info("Migration complete")
    }

    static func markDone() {
        UserDefaults.standard.set(true, forKey: migratedKey)
    }

    // MARK: - 3.0 First-Launch Migration

    private static let v3MigratedKey = "doomcoder.migration.v3.done"

    /// Runs once on 3.0 first launch: migrates ChannelStore v2→v3,
    /// purges all ntfy UserDefaults keys, and removes ntfy keychain entries.
    static func migrateToV3IfNeeded() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: v3MigratedKey) else { return }

        // 1. Migrate ChannelStore v2 → v3 (ntfy → iosCompanion)
        ChannelStore.migrateV2toV3IfNeeded()

        // 2. Wipe ntfy UserDefaults keys
        let ntfyKeys = [
            "doomcoder.ntfy.topic",
            "doomcoder.ntfy.server",
            "doomcoder.ntfy.keychainMigrated.v1",
            "doomcoder.channels.v2"
        ]
        for key in ntfyKeys { ud.removeObject(forKey: key) }

        // 3. Remove ntfy keychain entry (service = "doomcoder.ntfy")
        let keychainQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "doomcoder.ntfy" as CFString
        ]
        SecItemDelete(keychainQuery as CFDictionary)

        ud.set(true, forKey: v3MigratedKey)
        logger.info("3.0 migration complete — ntfy purged")
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
