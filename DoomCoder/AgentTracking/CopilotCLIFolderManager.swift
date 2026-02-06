import Foundation
import OSLog

// Manages registered folders for Copilot CLI hooks installation.
// Copilot CLI hooks are per-project (hooks.json in each folder).
enum CopilotCLIFolderManager {
    private static let defaultsKey = "doomcoder.copilotcli.folders"
    private static let logger = Logger(subsystem: "com.doomcoder", category: "cli-folders")

    /// Returns currently registered folder paths.
    static var folders: [URL] {
        get {
            let paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
            return paths.map { URL(fileURLWithPath: $0) }
        }
    }

    static func addFolder(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        let p = url.path
        guard !paths.contains(p) else { return }
        paths.append(p)
        UserDefaults.standard.set(paths, forKey: defaultsKey)
        logger.info("Added CLI folder: \(p, privacy: .public)")
    }

    static func removeFolder(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: defaultsKey)
        logger.info("Removed CLI folder: \(url.path, privacy: .public)")
    }

    static func folderCount() -> Int { folders.count }

    /// Install hooks in a specific folder.
    @discardableResult
    static func installHooks(in folder: URL) -> Result<Void, Error> {
        addFolder(folder)
        return AgentInstallerV2.install(.copilotCLI, folder: folder)
    }

    /// Uninstall hooks from a specific folder WITHOUT removing it from the folder list.
    /// Use this when the user clicks "Uninstall" on a per-folder row — hooks are deleted
    /// from disk but the folder stays registered so they can reinstall later.
    @discardableResult
    static func uninstallHooksFromFolder(_ folder: URL) -> Result<Void, Error> {
        AgentInstallerV2.uninstall(.copilotCLI, folder: folder)
    }

    /// Uninstall hooks from a specific folder AND remove it from the registered list.
    /// Use only when the user wants a full cleanup of a single folder entry.
    @discardableResult
    static func uninstallHooks(from folder: URL) -> Result<Void, Error> {
        let result = AgentInstallerV2.uninstall(.copilotCLI, folder: folder)
        removeFolder(folder)
        return result
    }

    /// Install hooks in all registered folders that do not yet have them.
    static func installMissing() {
        for folder in folders where !AgentInstallerV2.isInstalledCLI(folder: folder) {
            _ = AgentInstallerV2.install(.copilotCLI, folder: folder)
        }
    }

    /// Re-install hooks in every registered folder (overwrites any manual edits).
    static func reinstallAll() {
        for folder in folders {
            _ = AgentInstallerV2.install(.copilotCLI, folder: folder)
        }
    }

    /// Remove hooks from all registered folders WITHOUT removing them from the folder list.
    /// Useful when the user wants to temporarily disable tracking while keeping their folder list.
    static func uninstallHooksOnly() {
        for folder in folders {
            _ = AgentInstallerV2.uninstall(.copilotCLI, folder: folder)
        }
    }

    /// Remove ALL folders from the registered list WITHOUT touching hooks on disk.
    /// Hooks that were installed in these folders will remain on disk unchanged.
    static func removeAllFolders() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        logger.info("Cleared all registered CLI folders from list (hooks not touched)")
    }

    /// Uninstall from all registered folders AND clear the folder list.
    static func uninstallAll() {
        for folder in folders {
            _ = AgentInstallerV2.uninstall(.copilotCLI, folder: folder)
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Check which registered folders still have valid hooks installed.
    static func installedFolders() -> [URL] {
        folders.filter { AgentInstallerV2.isInstalledCLI(folder: $0) }
    }

    /// Heal paths in all registered folders.
    static func healAll() {
        for folder in folders {
            if AgentInstallerV2.isInstalledCLI(folder: folder) {
                _ = AgentInstallerV2.install(.copilotCLI, folder: folder)
            }
        }
    }

    // MARK: - Recents discovery

    /// Auto-suggest recent project folders from various sources.
    static func discoverRecentFolders() -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default

        // Source 1: Shell history - look for cd commands
        let historyPaths = [
            NSHomeDirectory() + "/.zsh_history",
            NSHomeDirectory() + "/.bash_history"
        ]
        for histPath in historyPaths {
            if let content = try? String(contentsOfFile: histPath, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n").suffix(500) // Last 500 lines
                for line in lines {
                    // Match `cd /path/to/project` patterns
                    if let range = line.range(of: "cd\\s+([~/][^;|&]+)", options: .regularExpression) {
                        var dir = String(line[range]).replacingOccurrences(of: "cd ", with: "").trimmingCharacters(in: .whitespaces)
                        if dir.hasPrefix("~") { dir = NSHomeDirectory() + dir.dropFirst() }
                        let url = URL(fileURLWithPath: dir)
                        if fm.fileExists(atPath: url.path) && !results.contains(url) {
                            results.append(url)
                        }
                    }
                }
            }
        }

        // Source 2: Common project directories (no ~/Desktop — accessing it
        // triggers macOS TCC permission prompts on every app rebuild).
        let projectDirs = [
            NSHomeDirectory() + "/Developer",
            NSHomeDirectory() + "/Projects",
            NSHomeDirectory() + "/Code",
            NSHomeDirectory() + "/src"
        ]
        for dir in projectDirs {
            if let children = try? fm.contentsOfDirectory(atPath: dir) {
                for child in children.prefix(20) {
                    let full = dir + "/" + child
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                        let url = URL(fileURLWithPath: full)
                        if !results.contains(url) { results.append(url) }
                    }
                }
            }
        }

        return Array(results.prefix(20))
    }
}
