import AppKit
import ApplicationServices
import OSLog

// MARK: - AX state hint

/// Coarse state hint derived from reading AX attributes on the active IDE window.
/// Supplements hook events with a visual-layer signal for cases where hooks are
/// delayed (e.g. long tool calls) or not yet installed.
enum AXStateHint: Sendable {
    case working   // progress bar visible / spinner / running indicator
    case idle      // normal editing state, no obvious activity indicator
    case unknown   // AX permission denied or element not found
}

// Watches which IDE window is frontmost and extracts its working directory.
//
// Uses NSWorkspace activation notifications + AXUIElement window-title parsing.
// Accessibility permission IS required to read kAXTitleAttribute on third-party
// processes. Without it, AX calls return .noValue and CWD extraction fails; we
// still report which agent is frontmost but cwd will be empty.
//
// AX calls run off the main actor (Task.detached) because they can block for
// hundreds of ms when the target app is busy.

@Observable
@MainActor
final class ActiveAppMonitor {
    static let shared = ActiveAppMonitor()

    struct FrontmostEntry: Equatable {
        let agent: TrackedAgent
        let cwd: String   // empty when AX title parse fails or terminal CLI
    }

    private(set) var frontmost: FrontmostEntry? = nil

    /// Latest AX hint per agent (updated off-main-thread, published on main).
    private(set) var axHints: [TrackedAgent: AXStateHint] = [:]

    /// Callback fired whenever an AX hint changes. Set by `AgentTrackingManager`.
    var onAXHint: ((TrackedAgent, AXStateHint) -> Void)?

    private let logger = Logger(subsystem: "com.doomcoder", category: "activemonitor")
    private var activationObserver: (any NSObjectProtocol)?

    // Bundle IDs we recognize as IDE processes
    static let bundleToAgent: [String: TrackedAgent] = [
        "com.todesktop.230313mzl4w4u92":  .cursor,
        "com.microsoft.VSCode":            .vscode,
        "com.microsoft.VSCodeInsiders":    .vscode,
        "com.exafunction.windsurf":        .windsurf,
        "com.codeium.windsurf":            .windsurf,
    ]

    // Terminal emulators — we pgrep for CLI agents when these are frontmost
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
    ]

    private init() {}

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.handleActivation(app) }
        }
        if let current = NSWorkspace.shared.frontmostApplication {
            handleActivation(current)
        }
        logger.debug("ActiveAppMonitor started")
    }

    func stop() {
        if let obs = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            activationObserver = nil
        }
    }

    // MARK: - Activation

    private func handleActivation(_ app: NSRunningApplication) {
        let bundleID = app.bundleIdentifier ?? ""
        let pid = app.processIdentifier

        if let agent = Self.bundleToAgent[bundleID] {
            Task.detached(priority: .userInitiated) { [weak self] in
                let cwd = Self.extractCWD(pid: pid) ?? ""
                await MainActor.run { [weak self] in
                    self?.frontmost = FrontmostEntry(agent: agent, cwd: cwd)
                    self?.logger.debug("frontmost: \(agent.rawValue, privacy: .public) cwd=\(cwd, privacy: .public)")
                }
            }
        } else if Self.terminalBundleIDs.contains(bundleID) {
            Task.detached(priority: .userInitiated) { [weak self] in
                let agent = Self.cliAgentInTerminal()
                await MainActor.run { [weak self] in
                    if let agent {
                        self?.frontmost = FrontmostEntry(agent: agent, cwd: "")
                        self?.logger.debug("frontmost CLI: \(agent.rawValue, privacy: .public)")
                    } else {
                        self?.frontmost = nil
                    }
                }
            }
        } else {
            frontmost = nil
        }
    }

    // MARK: - AX title → CWD (nonisolated, called from Task.detached)

    nonisolated private static func extractCWD(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        if let title = focusedWindowTitle(axApp) ?? firstWindowTitle(axApp) {
            return parseCWD(from: title)
        }
        return nil
    }

    nonisolated private static func focusedWindowTitle(_ axApp: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let win = ref else { return nil }
        return windowTitle(win as! AXUIElement)
    }

    nonisolated private static func firstWindowTitle(_ axApp: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement],
              let first = wins.first else { return nil }
        return windowTitle(first)
    }

    nonisolated private static func windowTitle(_ win: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &ref) == .success,
              let title = ref as? String, !title.isEmpty else { return nil }
        return title
    }

    // Parse working directory from IDE window titles:
    //   "main.swift — /Users/foo/myapp — Cursor"
    //   "/Users/foo/myapp — Visual Studio Code"
    //   "~/myapp — Windsurf"
    nonisolated private static func parseCWD(from title: String) -> String? {
        for sep in [" — ", " - ", " | "] {
            let parts = title.components(separatedBy: sep)
            for part in parts.reversed() {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                var candidate: String? = nil
                if trimmed.hasPrefix("/") && !trimmed.hasSuffix(".app") && trimmed.count > 2 {
                    candidate = trimmed
                } else if trimmed.hasPrefix("~/") {
                    candidate = NSHomeDirectory() + String(trimmed.dropFirst(1))
                }
                if let path = candidate {
                    // Strip to directory if the candidate looks like a file path
                    // (has a file extension in the last component).
                    let url = URL(fileURLWithPath: path)
                    if !url.pathExtension.isEmpty {
                        let dir = url.deletingLastPathComponent().path
                        return dir.isEmpty ? path : dir
                    }
                    return path
                }
            }
        }
        return nil
    }

    // MARK: - AX state hints

    /// Read a coarse working/idle hint from an IDE window by probing for a
    /// VS Code / Cursor / Windsurf "Copilot" or "thinking" status-bar item.
    /// Must be called from a background thread (AX calls can block).
    nonisolated static func readStatusBarHint(pid: pid_t) -> AXStateHint {
        let axApp = AXUIElementCreateApplication(pid)
        if let hint = searchForCopilotHint(in: axApp) { return hint }
        return .unknown
    }

    nonisolated private static func searchForCopilotHint(in axApp: AXUIElement) -> AXStateHint? {
        var ref: CFTypeRef?
        // Try menu-bar-extra or status-bar items for the spinner icon
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &ref) == .success,
              let bar = ref else { return nil }
        var childRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return nil }
        for child in children {
            var descRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &descRef) == .success,
               let desc = descRef as? String {
                let lower = desc.lowercased()
                if lower.contains("copilot") || lower.contains("generating") || lower.contains("thinking") {
                    return lower.contains("generating") || lower.contains("thinking") ? .working : .idle
                }
            }
        }
        return nil
    }

    // MARK: - CLI agent detection via pgrep

    nonisolated private static func cliAgentInTerminal() -> TrackedAgent? {
        let checks: [(TrackedAgent, String)] = [
            (.claude,     "pgrep -x claude"),
            (.copilotCLI, "pgrep -f 'gh copilot' 2>/dev/null | grep -v pgrep"),
            (.codexCLI,   "pgrep -x codex"),
        ]
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        for (agent, cmd) in checks {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: shell)
            proc.arguments = ["-lc", "\(cmd) | head -1"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !(out?.isEmpty ?? true) { return agent }
                }
            }
        }
        return nil
    }
}
