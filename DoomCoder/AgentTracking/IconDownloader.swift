import Foundation
import AppKit
import OSLog

// Downloads real agent icons from the lobehub @lobehub/icons-static-png CDN
// and caches them in ~/Library/Application Support/DoomCoder/icons/cdn-{agent}.png.
// Only fetches once per agent; network errors silently fall back to SF Symbols.
enum IconDownloader {
    private static let cdnBase =
        "https://cdn.jsdelivr.net/npm/@lobehub/icons-static-png@1.90.0/light"

    private static let logger = Logger(subsystem: "com.doomcoder", category: "icons")

    // Maps each CLI/IDE agent to its lobehub filename.
    // .vscode has no lobehub entry — its icon comes from the installed .app bundle.
    private static let cdnFilenames: [TrackedAgent: String] = [
        .claude:     "claudecode-color.png",
        .codexCLI:   "codex-color.png",
        .copilotCLI: "githubcopilot.png",
        .cursor:     "cursor.png",
        .windsurf:   "windsurf.png",
    ]

    // MARK: - Public API

    /// URL for the cached CDN icon (may not exist yet if download is pending).
    static func cdnCacheURL(for agent: TrackedAgent) -> URL {
        let dir = AgentSupportDir.url.appendingPathComponent("icons", isDirectory: true)
        return dir.appendingPathComponent("cdn-\(agent.rawValue).png")
    }

    /// Returns the cached CDN icon if it has already been downloaded.
    static func cachedIcon(for agent: TrackedAgent, size: CGFloat = 32) -> NSImage? {
        let url = cdnCacheURL(for: agent)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: size, height: size)
        return image
    }

    /// Kicks off background downloads for all agents that have CDN icons and
    /// whose cache file does not yet exist. Safe to call on every app launch —
    /// already-downloaded icons are skipped. Posts .doomCoderIconsRefreshed on
    /// MainActor after all downloads complete so icon-displaying views can refresh.
    static func prefetch() {
        Task.detached(priority: .utility) {
            let iconsDir = AgentSupportDir.url.appendingPathComponent("icons", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: iconsDir, withIntermediateDirectories: true)

            await withTaskGroup(of: Void.self) { group in
                for (agent, filename) in cdnFilenames {
                    let dest = cdnCacheURL(for: agent)
                    guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
                    group.addTask { await download(filename: filename, to: dest) }
                }
            }

            // Notify icon-displaying views so they can refresh immediately after
            // CDN icons land — otherwise cached icons only appear on the next
            // natural re-render (e.g. toggle or timer tick).
            await MainActor.run {
                NotificationCenter.default.post(name: .doomCoderIconsRefreshed, object: nil)
            }
        }
    }

    // MARK: - Private

    private static func download(filename: String, to dest: URL) async {
        guard let url = URL(string: "\(cdnBase)/\(filename)") else { return }
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty else {
                logger.warning("CDN non-200 or empty for \(filename, privacy: .public)")
                return
            }
            // Data.write(to:options:.atomic) handles temp-file-and-rename internally
            // and works whether or not the destination exists yet.
            try data.write(to: dest, options: .atomic)
            logger.debug("icon cached: \(dest.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("icon download failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Notification.Name {
    static let doomCoderIconsRefreshed = Notification.Name("doomcoder.icons.refreshed")
}
