import Foundation
import AppKit
import OSLog

struct AgentDetection: Equatable, Sendable {
    let agent: TrackedAgent
    let installed: Bool
    let version: String?
    let details: String?
    let runState: AgentRunState

    init(agent: TrackedAgent, installed: Bool, version: String?, details: String?, runState: AgentRunState? = nil) {
        self.agent = agent
        self.installed = installed
        self.version = version
        self.details = details
        // Default: if we know it's installed but haven't probed runState
        // separately, expose `.installed`; if not installed, `.notInstalled`.
        self.runState = runState ?? (installed ? .installed : .notInstalled)
    }
}

enum AgentDetector {
    private static let logger = Logger(subsystem: "com.doomcoder", category: "detector")

    static func detectAll() -> [AgentDetection] { TrackedAgent.allCases.map(detect) }

    static func detect(_ agent: TrackedAgent) -> AgentDetection {
        let base: AgentDetection = {
            switch agent {
            case .claude:      return detectClaude()
            case .cursor:      return detectCursor()
            case .vscode:      return detectVSCode()
            case .copilotCLI:  return detectCopilotCLI()
            case .windsurf:    return detectWindsurf()
            case .codexCLI:    return detectCodexCLI()
            }
        }()
        guard base.installed else { return base }
        let rs = probeRunState(agent)
        return AgentDetection(agent: base.agent, installed: base.installed,
                              version: base.version, details: base.details,
                              runState: rs)
    }

    // MARK: - Run-state probe
    //
    // .app-based agents: probed via NSWorkspace bundle ID match (cheap,
    // accurate, no spawning processes).
    // CLI agents: probed via `pgrep -fl <pattern>` in a login shell so we
    // pick up CLIs launched from anywhere in PATH. Pattern matches both
    // the binary name and common Node-shim invocations (`node .../copilot`).
    //
    // We do NOT yet upgrade to `.active` here — that requires the
    // last-hook-event-recency check, which lives in AgentTrackingManager
    // where the event store is reachable. v2.3.0 ships the binary
    // installed/running signal; recency-upgrade can be wired in a later
    // pass without rev'ing this API.

    static func probeRunState(_ agent: TrackedAgent) -> AgentRunState {
        switch agent {
        case .cursor:
            return isAppRunning(bundleIDs: ["com.todesktop.230313mzl4w4u92"]) ? .running : .installed
        case .vscode:
            return isAppRunning(bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]) ? .running : .installed
        case .windsurf:
            return isAppRunning(bundleIDs: ["com.exafunction.windsurf", "com.codeium.windsurf"]) ? .running : .installed
        case .claude:
            return isCLIRunning(patterns: ["claude"]) ? .running : .installed
        case .copilotCLI:
            return isCLIRunning(patterns: ["copilot", "gh copilot"]) ? .running : .installed
        case .codexCLI:
            return isCLIRunning(patterns: ["codex"]) ? .running : .installed
        }
    }

    private static func isAppRunning(bundleIDs: [String]) -> Bool {
        let running = NSWorkspace.shared.runningApplications
        return running.contains { app in
            guard let id = app.bundleIdentifier else { return false }
            return bundleIDs.contains(id)
        }
    }

    /// Match by command-name (basename) to avoid spurious hits on file
    /// paths or grep itself. Uses pgrep -x where possible.
    private static func isCLIRunning(patterns: [String]) -> Bool {
        for p in patterns {
            // -x is exact match on the command name. Falls back to -f if
            // multi-word (`gh copilot`).
            let cmd = p.contains(" ")
                ? "pgrep -fl '\(p)' 2>/dev/null | grep -v pgrep | head -1"
                : "pgrep -x '\(p)' 2>/dev/null | head -1"
            if let _ = runLoginShell(cmd) { return true }
        }
        return false
    }

    private static func detectClaude() -> AgentDetection {
        let dir = NSHomeDirectory() + "/.claude"
        let dirExists = FileManager.default.fileExists(atPath: dir)
        // Use login shell to find claude in user's full PATH
        let version = runLoginShell("command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null")
        return AgentDetection(agent: .claude,
                              installed: dirExists || version != nil,
                              version: version,
                              details: dirExists ? dir : nil)
    }

    private static func detectCursor() -> AgentDetection {
        let paths = ["/Applications/Cursor.app", NSHomeDirectory() + "/Applications/Cursor.app"]
        let path = paths.first { FileManager.default.fileExists(atPath: $0) }
        var version: String?
        if let p = path,
           let plist = NSDictionary(contentsOfFile: "\(p)/Contents/Info.plist"),
           let v = plist["CFBundleShortVersionString"] as? String { version = v }
        return AgentDetection(agent: .cursor, installed: path != nil, version: version, details: path)
    }

    private static func detectVSCode() -> AgentDetection {
        let paths = [
            "/Applications/Visual Studio Code.app",
            NSHomeDirectory() + "/Applications/Visual Studio Code.app",
            "/Applications/Visual Studio Code - Insiders.app"
        ]
        let path = paths.first { FileManager.default.fileExists(atPath: $0) }
        var version: String?
        if let p = path,
           let plist = NSDictionary(contentsOfFile: "\(p)/Contents/Info.plist"),
           let v = plist["CFBundleShortVersionString"] as? String { version = v }
        return AgentDetection(agent: .vscode, installed: path != nil, version: version, details: path)
    }

    // D12: Multi-probe Copilot CLI detection
    // 1. Login shell `command -v copilot`
    // 2. gh extension list (copilot installed as gh extension)
    // 3. npm/volta/n/homebrew global paths
    // 4. ~/.copilot/ directory presence
    private static func detectCopilotCLI() -> AgentDetection {
        // Probe 1: Login shell finds copilot binary
        let version = runLoginShell("command -v copilot >/dev/null 2>&1 && copilot --version 2>/dev/null")
        if let version { return AgentDetection(agent: .copilotCLI, installed: true, version: version, details: "copilot binary") }

        // Probe 2: gh copilot extension
        let ghExt = runLoginShell("gh extension list 2>/dev/null | grep -i copilot")
        if let ghExt { return AgentDetection(agent: .copilotCLI, installed: true, version: nil, details: "gh extension: \(ghExt)") }

        // Probe 3: Check common global install paths
        let globalPaths = [
            "/opt/homebrew/bin/copilot",
            "/usr/local/bin/copilot",
            NSHomeDirectory() + "/.volta/bin/copilot",
            NSHomeDirectory() + "/.npm-global/bin/copilot",
            NSHomeDirectory() + "/.local/bin/copilot"
        ]
        for gp in globalPaths {
            if FileManager.default.fileExists(atPath: gp) {
                let ver = runCapture(gp, ["--version"])
                return AgentDetection(agent: .copilotCLI, installed: true, version: ver, details: gp)
            }
        }

        // Probe 4: Check if GitHub Copilot CLI config dir exists
        let copilotDir = NSHomeDirectory() + "/.copilot"
        if FileManager.default.fileExists(atPath: copilotDir) {
            return AgentDetection(agent: .copilotCLI, installed: true, version: nil, details: "~/.copilot/ exists")
        }

        // Probe 5: Check if copilot is available via `gh copilot`
        let ghCopilot = runLoginShell("gh copilot --version 2>/dev/null")
        if let ghCopilot { return AgentDetection(agent: .copilotCLI, installed: true, version: ghCopilot, details: "gh copilot") }

        return AgentDetection(agent: .copilotCLI, installed: false, version: nil, details: nil)
    }

    private static func detectWindsurf() -> AgentDetection {
        let paths = ["/Applications/Windsurf.app", NSHomeDirectory() + "/Applications/Windsurf.app"]
        let path = paths.first { FileManager.default.fileExists(atPath: $0) }
        var version: String?
        if let p = path,
           let plist = NSDictionary(contentsOfFile: "\(p)/Contents/Info.plist"),
           let v = plist["CFBundleShortVersionString"] as? String { version = v }
        // Also detect via ~/.codeium/windsurf/ directory (JetBrains plugin or no app)
        let codeiumDir = NSHomeDirectory() + "/.codeium/windsurf"
        let dirExists = FileManager.default.fileExists(atPath: codeiumDir)
        return AgentDetection(agent: .windsurf, installed: path != nil || dirExists,
                              version: version, details: path ?? (dirExists ? codeiumDir : nil))
    }

    private static func detectCodexCLI() -> AgentDetection {
        // Probe 1: ~/.codex directory exists (Codex CLI's config home).
        let codexDir = NSHomeDirectory() + "/.codex"
        let dirExists = FileManager.default.fileExists(atPath: codexDir)
        // Probe 2: login-shell PATH lookup.
        let version = runLoginShell("command -v codex >/dev/null 2>&1 && codex --version 2>/dev/null")
        return AgentDetection(agent: .codexCLI,
                              installed: dirExists || version != nil,
                              version: version,
                              details: dirExists ? codexDir : nil)
    }

    // MARK: - Shell helpers

    /// Run a command in the user's login shell to get full PATH resolution.
    /// This fixes the GUI-app PATH limitation (B5).
    private static func runLoginShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
        return runCapture(shell, ["-lc", command])
    }

    private static func runCapture(_ exec: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exec)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty ?? true) ? nil : s
        } catch { return nil }
    }
}
