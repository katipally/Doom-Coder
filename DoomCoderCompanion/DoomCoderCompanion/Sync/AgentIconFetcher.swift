// AgentIconFetcher.swift — DoomCoder Companion
// Downloads agent icons from the same lobehub CDN as the Mac app and caches
// them in the App Group container so the Notification Service Extension can
// attach them to banners without an extra network call.

import Foundation
import DoomCoderCore

enum AgentIconFetcher {

    private static let cdnBase =
        "https://cdn.jsdelivr.net/npm/@lobehub/icons-static-png@1.90.0/light"

    // CDN filename → TrackedAgent.iconSlug (the App Group cache key).
    private static let entries: [(filename: String, slug: String)] = [
        ("claudecode-color.png", "claude"),
        ("cursor.png",           "cursor"),
        ("vscode-color.png",     "vscode"),
        ("githubcopilot.png",    "github-copilot"),
        ("windsurf.png",         "windsurf"),
        ("codex-color.png",      "openai"),
    ]

    /// Downloads any missing agent icons into the App Group `icons/` directory.
    /// Skips icons that are already on disk. Runs entirely on a background task.
    static func prefetchIfNeeded() {
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for entry in entries {
                    // Skip if already cached.
                    guard AppGroupCache.iconURL(slug: entry.slug) == nil else { continue }
                    group.addTask { await download(filename: entry.filename, slug: entry.slug) }
                }
            }
        }
    }

    private static func download(filename: String, slug: String) async {
        guard let url = URL(string: "\(cdnBase)/\(filename)") else { return }
        do {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue("DoomCoderCompanion/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                print("[AgentIconFetcher] bad response for \(filename)")
                return
            }
            AppGroupCache.writeIcon(slug: slug, data: data)
            print("[AgentIconFetcher] cached \(slug).png (\(data.count) bytes)")
        } catch {
            print("[AgentIconFetcher] download failed for \(filename): \(error.localizedDescription)")
        }
    }
}
