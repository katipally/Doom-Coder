import Foundation
import AppKit
import OSLog

// Deep-link helpers: Reveal file in Finder and open in native IDE settings.
enum DeepLink {
    private static let logger = Logger(subsystem: "com.doomcoder", category: "deeplink")

    /// Reveal the hooks config file for an agent in Finder.
    static func revealInFinder(_ agent: TrackedAgent, folder: URL? = nil) {
        let path = AgentInstallerV2.configPath(for: agent, folder: folder)
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Open parent dir
            let parent = url.deletingLastPathComponent()
            NSWorkspace.shared.open(parent)
        }
    }

    /// Best-effort open in the native IDE or editor.
    static func openInIDE(_ agent: TrackedAgent, folder: URL? = nil) {
        switch agent {
        case .claude:
            openFileInDefaultEditor(AgentInstallerV2.claudeSettingsPath())

        case .cursor:
            // Try to open cursor and navigate to hooks file
            let bid = "com.todesktop.230313mzl4w4u92"
            let hookFile = AgentInstallerV2.cursorHooksPath()
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                NSWorkspace.shared.open(
                    [URL(fileURLWithPath: hookFile)],
                    withApplicationAt: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } else {
                openFileInDefaultEditor(hookFile)
            }

        case .vscode:
            // Use `code` CLI to open the hooks-related settings page
            let vscodeCliBins = [
                "/usr/local/bin/code",
                "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
                NSHomeDirectory() + "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
            ]
            if let codeBin = vscodeCliBins.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: codeBin)
                task.arguments = ["--command", "workbench.action.openSettings", "@id:chat.hookFilesLocations"]
                try? task.run()
            } else {
                openFileInDefaultEditor(AgentInstallerV2.claudeSettingsPath())
            }

        case .copilotCLI:
            if let folder = folder {
                let hooksFile = AgentInstallerV2.configPath(for: .copilotCLI, folder: folder)
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hooksFile)])
            }
        }
    }

    private static func openFileInDefaultEditor(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
