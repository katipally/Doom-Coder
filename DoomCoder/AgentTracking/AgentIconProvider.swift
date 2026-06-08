import Foundation
import AppKit

// Provides agent icons. Priority order:
//   1. NSWorkspace runtime icon from installed .app bundle (IDE agents only)
//   2. Bundled xcassets icon — instant, no network (CLI agents)
//   3. Cached CDN icon downloaded from lobehub @lobehub/icons-static-png
//   4. SF Symbol fallback (always available)
//
// Bundled icons are embedded in the app at build time. CDN fetch via
// IconDownloader.prefetch() acts as an update path for when icons change.
enum AgentIconProvider {
    /// Returns an NSImage for the given agent.
    static func icon(for agent: TrackedAgent, size: CGFloat = 32) -> NSImage {
        switch agent {
        case .claude:
            // Bundled first — available without network on first launch.
            if let bundled = NSImage(named: "agent-claude") {
                bundled.size = NSSize(width: size, height: size)
                return bundled
            }
            if let cdn = IconDownloader.cachedIcon(for: .claude, size: size) { return cdn }
            return bundledOrSymbol(name: "agent-claude", symbol: "c.circle.fill", size: size)
        case .cursor:
            if let appIcon = appIcon(bundleIds: ["com.todesktop.230313mzl4w4u92"],
                                     paths: ["/Applications/Cursor.app",
                                             NSHomeDirectory() + "/Applications/Cursor.app"],
                                     size: size) { return appIcon }
            if let cdn = IconDownloader.cachedIcon(for: .cursor, size: size) { return cdn }
            return bundledOrSymbol(name: "agent-cursor", symbol: "cursorarrow.rays", size: size)
        case .vscode:
            // No lobehub icon for VS Code — use installed app icon only.
            if let appIcon = appIcon(bundleIds: ["com.microsoft.VSCode",
                                                 "com.microsoft.VSCodeInsiders"],
                                     paths: ["/Applications/Visual Studio Code.app",
                                             NSHomeDirectory() + "/Applications/Visual Studio Code.app",
                                             "/Applications/Visual Studio Code - Insiders.app"],
                                     size: size) { return appIcon }
            return bundledOrSymbol(name: "agent-vscode",
                                   symbol: "chevron.left.forwardslash.chevron.right", size: size)
        case .copilotCLI:
            if let bundled = NSImage(named: "agent-copilot-cli") {
                bundled.size = NSSize(width: size, height: size)
                return bundled
            }
            if let cdn = IconDownloader.cachedIcon(for: .copilotCLI, size: size) { return cdn }
            return bundledOrSymbol(name: "agent-copilot-cli", symbol: "terminal.fill", size: size)
        case .windsurf:
            if let appIcon = appIcon(bundleIds: ["com.codeium.windsurf", "com.exafunction.windsurf"],
                                     paths: ["/Applications/Windsurf.app",
                                             NSHomeDirectory() + "/Applications/Windsurf.app"],
                                     size: size) { return appIcon }
            if let cdn = IconDownloader.cachedIcon(for: .windsurf, size: size) { return cdn }
            return bundledOrSymbol(name: "agent-windsurf", symbol: "wind", size: size)
        case .codexCLI:
            // Bundled first — available without network on first launch.
            if let bundled = NSImage(named: "agent-codex") {
                bundled.size = NSSize(width: size, height: size)
                return bundled
            }
            if let cdn = IconDownloader.cachedIcon(for: .codexCLI, size: size) { return cdn }
            return bundledOrSymbol(name: "agent-codex",
                                   symbol: "sparkles.rectangle.stack", size: size)
        case .opencode:
            // Bundled first — available without network on first launch.
            if let bundled = NSImage(named: "agent-opencode") {
                bundled.size = NSSize(width: size, height: size)
                return bundled
            }
            if let cdn = IconDownloader.cachedIcon(for: .opencode, size: size) { return cdn }
            return bundledOrSymbol(name: "agent-opencode", symbol: "curlybraces", size: size)
        }
    }

    /// System name for SF Symbol fallback per agent.
    static func sfSymbol(for agent: TrackedAgent) -> String {
        switch agent {
        case .claude:     return "c.circle.fill"
        case .cursor:     return "cursorarrow.rays"
        case .vscode:     return "chevron.left.forwardslash.chevron.right"
        case .copilotCLI: return "terminal.fill"
        case .windsurf:   return "wind"
        case .codexCLI:   return "sparkles.rectangle.stack"
        case .opencode:   return "curlybraces"
        }
    }

    // MARK: - Notification attachment URL

    /// Returns a file URL to a PNG of the agent icon suitable for
    /// UNNotificationAttachment.
    ///
    /// Priority:
    ///   1. CDN-downloaded icon (best quality, downloaded by IconDownloader.prefetch())
    ///   2. Rendered fallback (SF Symbol / app icon rendered to PNG, cached on disk)
    static func iconFileURL(for agent: TrackedAgent) -> URL? {
        let cacheDir = AgentSupportDir.url.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Prefer the CDN icon if already cached.
        let cdnURL = IconDownloader.cdnCacheURL(for: agent)
        if FileManager.default.fileExists(atPath: cdnURL.path) { return cdnURL }

        // Fall back to a locally rendered PNG (SF Symbol or app icon).
        let rendered = cacheDir.appendingPathComponent("\(agent.rawValue)-render.png")
        if FileManager.default.fileExists(atPath: rendered.path) { return rendered }
        let image = icon(for: agent, size: 64)
        guard let data = image.pngData() else { return nil }
        try? data.write(to: rendered)
        return rendered
    }

    // MARK: - Private

    private static func appIcon(bundleIds: [String], paths: [String], size: CGFloat) -> NSImage? {
        // Try to get icon via NSWorkspace for each bundle ID
        for bid in bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: size, height: size)
                return icon
            }
        }
        // Try direct paths
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: size, height: size)
                return icon
            }
        }
        return nil
    }

    private static func bundledOrSymbol(name: String, symbol: String, size: CGFloat) -> NSImage {
        if let bundled = NSImage(named: name) {
            bundled.size = NSSize(width: size, height: size)
            return bundled
        }
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .medium)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
            .withSymbolConfiguration(config) ?? NSImage()
    }

}

// MARK: - NSImage PNG export

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
