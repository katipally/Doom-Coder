import Foundation
import AppKit

// Provides agent icons. Priority order:
//   1. Bundled asset catalog PNG (always available, offline-capable)
//   2. NSWorkspace runtime icon from installed .app bundle (IDE agents — better match to what user sees)
//   3. SF Symbol fallback (always available)
enum AgentIconProvider {

    /// Returns an NSImage for the given agent.
    static func icon(for agent: TrackedAgent, size: CGFloat = 32) -> NSImage {
        // Bundled PNG first — shipped with app, always available
        if let bundled = NSImage(named: bundledAssetName(for: agent)) {
            return sized(bundled, size: size)
        }
        // IDE agents: try installed .app icon as a nice bonus
        if let appIcon = installedAppIcon(for: agent, size: size) {
            return appIcon
        }
        // SF Symbol last resort
        return sfSymbolImage(for: agent, size: size)
    }

    /// SF Symbol name per agent (for menus, toolbars, etc.)
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

    /// Returns a file URL to a PNG of the agent icon for UNNotificationAttachment.
    /// Renders and caches the bundled icon on first call.
    static func iconFileURL(for agent: TrackedAgent) -> URL? {
        let cacheDir = AgentSupportDir.url.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let rendered = cacheDir.appendingPathComponent("\(agent.rawValue)-icon.png")
        if FileManager.default.fileExists(atPath: rendered.path) { return rendered }

        let image = icon(for: agent, size: 128)
        guard let data = image.pngData() else { return nil }
        try? data.write(to: rendered)
        return rendered
    }

    // MARK: - Private

    private static func bundledAssetName(for agent: TrackedAgent) -> String {
        switch agent {
        case .claude:     return "agent-claude"
        case .cursor:     return "agent-cursor"
        case .vscode:     return "agent-vscode"
        case .copilotCLI: return "agent-copilot"
        case .windsurf:   return "agent-windsurf"
        case .codexCLI:   return "agent-codex"
        }
    }

    private static func installedAppIcon(for agent: TrackedAgent, size: CGFloat) -> NSImage? {
        switch agent {
        case .cursor:
            return appIcon(bundleIds: ["com.todesktop.230313mzl4w4u92"],
                           paths: ["/Applications/Cursor.app",
                                   NSHomeDirectory() + "/Applications/Cursor.app"],
                           size: size)
        case .vscode:
            return appIcon(bundleIds: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
                           paths: ["/Applications/Visual Studio Code.app",
                                   NSHomeDirectory() + "/Applications/Visual Studio Code.app",
                                   "/Applications/Visual Studio Code - Insiders.app"],
                           size: size)
        case .windsurf:
            return appIcon(bundleIds: ["com.codeium.windsurf", "com.exafunction.windsurf"],
                           paths: ["/Applications/Windsurf.app",
                                   NSHomeDirectory() + "/Applications/Windsurf.app"],
                           size: size)
        default:
            return nil
        }
    }

    private static func appIcon(bundleIds: [String], paths: [String], size: CGFloat) -> NSImage? {
        for bid in bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return sized(NSWorkspace.shared.icon(forFile: url.path), size: size)
            }
        }
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return sized(NSWorkspace.shared.icon(forFile: path), size: size)
            }
        }
        return nil
    }

    private static func sized(_ image: NSImage, size: CGFloat) -> NSImage {
        image.size = NSSize(width: size, height: size)
        return image
    }

    private static func sfSymbolImage(for agent: TrackedAgent, size: CGFloat) -> NSImage {
        let sym = sfSymbol(for: agent)
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .medium)
        return NSImage(systemSymbolName: sym, accessibilityDescription: sym)?
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
