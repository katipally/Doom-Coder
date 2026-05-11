import Foundation
import AppKit

// Provides agent icons: tries NSWorkspace runtime icons for .app bundles,
// falls back to bundled assets, then SF Symbols. All icons are local —
// no network calls, no third-party logo services.
enum AgentIconProvider {
    /// Returns an NSImage for the given agent. Tries runtime app icon first,
    /// then bundled asset catalog image, then SF Symbol fallback.
    static func icon(for agent: TrackedAgent, size: CGFloat = 32) -> NSImage {
        switch agent {
        case .claude:
            return bundledOrSymbol(name: "agent-claude", symbol: "c.circle.fill", size: size)
        case .cursor:
            if let appIcon = appIcon(bundleIds: ["com.todesktop.230313mzl4w4u92"],
                                      paths: ["/Applications/Cursor.app",
                                              NSHomeDirectory() + "/Applications/Cursor.app"],
                                      size: size) {
                return appIcon
            }
            return bundledOrSymbol(name: "agent-cursor", symbol: "cursorarrow.rays", size: size)
        case .vscode:
            if let appIcon = appIcon(bundleIds: ["com.microsoft.VSCode",
                                                  "com.microsoft.VSCodeInsiders"],
                                      paths: ["/Applications/Visual Studio Code.app",
                                              NSHomeDirectory() + "/Applications/Visual Studio Code.app",
                                              "/Applications/Visual Studio Code - Insiders.app"],
                                      size: size) {
                return appIcon
            }
            return bundledOrSymbol(name: "agent-vscode", symbol: "chevron.left.forwardslash.chevron.right", size: size)
        case .copilotCLI:
            return bundledOrSymbol(name: "agent-copilot-cli", symbol: "terminal.fill", size: size)
        case .windsurf:
            if let appIcon = appIcon(bundleIds: ["com.codeium.windsurf", "com.exafunction.windsurf"],
                                      paths: ["/Applications/Windsurf.app",
                                              NSHomeDirectory() + "/Applications/Windsurf.app"],
                                      size: size) {
                return appIcon
            }
            return bundledOrSymbol(name: "agent-windsurf", symbol: "wind", size: size)
        case .codexCLI:
            return bundledOrSymbol(name: "agent-codex", symbol: "sparkles.rectangle.stack", size: size)
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
        }
    }

    // MARK: - Notification attachment URL

    /// Returns a file URL to a cached PNG of the agent icon suitable for
    /// UNNotificationAttachment. Creates the PNG cache on first call.
    static func iconFileURL(for agent: TrackedAgent) -> URL? {
        let cacheDir = AgentSupportDir.url.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent("\(agent.rawValue).png")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        let image = icon(for: agent, size: 64)
        guard let data = image.pngData() else { return nil }
        try? data.write(to: cached)
        return cached
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
