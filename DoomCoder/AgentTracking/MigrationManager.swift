import Foundation
import OSLog

// Detects v1.8.5 broken hook configs (entries with x-doomcoder tag or wrong
// schema) and prompts user to migrate to v2.
enum MigrationManager {
    private static let logger = Logger(subsystem: "com.doomcoder", category: "migration")
    private static let migratedKey = "doomcoder.migration.v1_to_v2.done"
    private static let migratedKeyV3 = "doomcoder.migration.v2_to_v3.done"

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
    /// Audit 2026-06: defensive idempotency guard. The `migratedKey`
    /// flag is normally checked in `checkNeeded`, but if a caller
    /// invokes `migrate(agents:)` directly (e.g. from the wizard
    /// "Migrate now" button after a partial run), we must not run
    /// the migration twice. `defer` sets the flag on the success
    /// path; an early return on the guard keeps it unset so a
    /// subsequent call can still attempt the migration.
    static func migrate(agents: [TrackedAgent]) {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else {
            logger.info("migrate: already done, skipping")
            return
        }
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
                // Per-folder legacy installs — strip any registered folder.
                for folder in legacyCopilotCLIFolders() {
                    let hooksFile = folder.appendingPathComponent(".github/hooks/doomcoder.json").path
                    AgentInstallerV2.backup(hooksFile)
                    try? FileManager.default.removeItem(atPath: hooksFile)
                }
            case .windsurf, .codexCLI:
                break
            }

            _ = AgentInstallerV2.install(agent)
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

    // MARK: - v2 → v3 (Copilot CLI per-folder → global; VS Code → dedicated file)

    /// Idempotent silent migration. Runs once on launch; flag persisted in
    /// `doomcoder.migration.v2_to_v3.done`. Cleans up legacy per-folder
    /// Copilot CLI hooks files and installs the new global file.
    static func migrateV2toV3() {
        if UserDefaults.standard.bool(forKey: migratedKeyV3) { return }
        defer { UserDefaults.standard.set(true, forKey: migratedKeyV3) }

        let legacyFolders = legacyCopilotCLIFolders()
        var anyLegacy = false
        for folder in legacyFolders {
            let hooksFile = folder.appendingPathComponent(".github/hooks/doomcoder.json").path
            if FileManager.default.fileExists(atPath: hooksFile) {
                AgentInstallerV2.backup(hooksFile)
                try? FileManager.default.removeItem(atPath: hooksFile)
                anyLegacy = true
            }
        }

        // If there is a v2 ~/.claude/settings.json VS Code dc-hook block,
        // strip those entries so the new dedicated file is the sole source.
        let claudePath = AgentInstallerV2.claudeSettingsPath()
        if FileManager.default.fileExists(atPath: claudePath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: claudePath)),
           var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let before = (try? JSONSerialization.data(withJSONObject: root))?.count ?? 0
            AgentInstallerV2.stripDcHookEntries(&root, agentToken: "vscode")
            AgentInstallerV2.pruneEmptyContainers(&root)
            let after = (try? JSONSerialization.data(withJSONObject: root))?.count ?? 0
            if before != after {
                AgentInstallerV2.backup(claudePath)
                if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                    try? out.write(to: URL(fileURLWithPath: claudePath), options: .atomic)
                }
            }
        }

        // Install global Copilot CLI hooks if user had any per-folder installs
        // OR if a v3 global file is missing while their UserDefault folder list
        // is non-empty. Either way, the install is idempotent.
        if anyLegacy || !legacyFolders.isEmpty || !AgentInstallerV2.isInstalled(.copilotCLI) {
            _ = AgentInstallerV2.install(.copilotCLI)
        }

        // Wipe the legacy folder list so a downgrade-then-upgrade can't
        // resurrect it.
        UserDefaults.standard.removeObject(forKey: "doomcoder.copilotcli.folders")
        UserDefaults.standard.removeObject(forKey: "doomcoder.copilotcli.folder_bookmarks")
        logger.notice("v2_to_v3 migration complete legacy_folders=\(legacyFolders.count) any=\(anyLegacy)")
    }

    /// Read the legacy `doomcoder.copilotcli.folders` UserDefault that the
    /// removed `CopilotCLIFolderManager` used to maintain. We tolerate both
    /// the bookmark-array shape and the plain-path-array shape.
    private static func legacyCopilotCLIFolders() -> [URL] {
        var out: [URL] = []
        if let arr = UserDefaults.standard.array(forKey: "doomcoder.copilotcli.folders") as? [String] {
            out.append(contentsOf: arr.map { URL(fileURLWithPath: $0) })
        }
        if let arr = UserDefaults.standard.array(forKey: "doomcoder.copilotcli.folder_bookmarks") as? [Data] {
            for data in arr {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    out.append(url)
                }
            }
        }
        return out
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
