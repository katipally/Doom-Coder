import Foundation
import OSLog

struct AgentDetection: Equatable, Sendable {
    let agent: TrackedAgent
    let installed: Bool
    let version: String?
    let details: String?
}

enum AgentDetector {
    private static let logger = Logger(subsystem: "com.doomcoder", category: "detector")

    static func detectAll() -> [AgentDetection] { TrackedAgent.allCases.map(detect) }

    static func detect(_ agent: TrackedAgent) -> AgentDetection {
        switch agent {
        case .claude:      return detectClaude()
        case .cursor:      return detectCursor()
        case .vscode:      return detectVSCode()
        case .copilotCLI:  return detectCopilotCLI()
        }
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
