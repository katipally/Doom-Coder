import Foundation
import AppKit
import OSLog

// Downloads real agent icons from the lobehub @lobehub/icons-static-png CDN
// and caches them in ~/Library/Application Support/DoomCoder/icons/cdn-{agent}.png.
// Only fetches once per agent; network errors silently fall back to SF Symbols.
// Bundled xcassets icons (added in v2.2.0) take priority — CDN acts as an
// optional update/refresh path.
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
        .opencode:   "opencode.png",
    ]

    // Maps CLI agents to their xcassets image names bundled in the app.
    // When a bundled asset is present, CDN download is skipped.
    private static let bundledAssetNames: [TrackedAgent: String] = [
        .claude:     "agent-claude",
        .codexCLI:   "agent-codex",
        .copilotCLI: "agent-copilot-cli",
        .opencode:   "agent-opencode",
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
    /// whose cache file does not yet exist. Agents already covered by a bundled
    /// xcassets icon are skipped — CDN fetch is unnecessary when icons ship in
    /// the app bundle. Posts .doomCoderIconsRefreshed on MainActor after all
    /// downloads complete so icon-displaying views can refresh.
    static func prefetch() {
        Task.detached(priority: .utility) {
            let iconsDir = AgentSupportDir.url.appendingPathComponent("icons", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: iconsDir, withIntermediateDirectories: true)

            await withTaskGroup(of: Void.self) { group in
                for (agent, filename) in cdnFilenames {
                    // Skip CDN download for agents whose icon is already bundled.
                    if let assetName = bundledAssetNames[agent],
                       NSImage(named: assetName) != nil {
                        continue
                    }
                    let dest = cdnCacheURL(for: agent)
                    guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
                    group.addTask { await download(filename: filename, to: dest) }
                }
            }

            await MainActor.run {
                NotificationCenter.default.post(name: .doomCoderIconsRefreshed, object: nil)
            }
        }
    }

    // MARK: - Private

    /// Audit 2026-06: disk-quota fallback. The icons cache is small
    /// (~20 KB per agent x 5 agents = ~100 KB total) so this is
    /// belt-and-braces, but a future larger cache (e.g. user avatars)
    /// would want this protection. We check the parent directory's
    /// available capacity before writing and skip the write — without
    /// deleting the existing file — when there's less than 1 MB free.
    private static let minimumFreeBytes: Int64 = 1_048_576 // 1 MB

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
            // Disk-quota guard: if the parent directory has less than
            // `minimumFreeBytes` free, skip the write. The next app
            // launch will retry. SF Symbol fallbacks in the UI ensure
            // the user never sees a missing icon.
            if !hasSufficientDiskSpace(for: dest) {
                logger.warning("insufficient disk space for icon \(filename, privacy: .public); skipping write")
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

    /// Returns true if the directory containing `url` has at least
    /// `minimumFreeBytes` of free space available. Uses
    /// `URLResourceKey.volumeAvailableCapacityForImportantUsageKey`
    /// so the result reflects space the system is willing to allocate
    /// to non-essential writes (excluding purgeable caches, which
    /// icon writes technically are not, but we want to be polite).
    private static func hasSufficientDiskSpace(for url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        if let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            return free >= minimumFreeBytes
        }
        // Fall back to .volumeAvailableCapacityKey (the older API).
        if let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let free = values.volumeAvailableCapacity {
            return Int64(free) >= minimumFreeBytes
        }
        // If we can't determine free space, allow the write — the
        // write itself will fail and be caught by the caller's
        // do/catch, leaving the user with the SF Symbol fallback.
        return true
    }
}

extension Notification.Name {
    static let doomCoderIconsRefreshed = Notification.Name("doomcoder.icons.refreshed")
}
