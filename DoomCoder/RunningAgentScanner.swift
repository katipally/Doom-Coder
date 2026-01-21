import Foundation
import AppKit
import Observation

// MARK: - RunningAgentScanner
//
// Discovers currently-running AI agent processes (GUI apps + CLI sessions)
// so the menubar can offer a point-and-click "Watch this agent" menu. This
// is separate from AgentStatusManager.sessions — a scanner hit becomes a
// _candidate_; only once the agent fires a hook do we have a confirmed
// session. The menubar merges both lists.
//
// Strategy:
//   • GUI apps → NSWorkspace.runningApplications, filter by bundle id.
//   • CLIs → `ps -Ao pid,ppid,stat,tty,comm,command` and match the comm.
//   • cwd per pid → `lsof -p <pid> -d cwd -Fn` (best-effort; may be empty).
//
// We refresh on demand (when the menu opens) — not on a timer — to avoid
// spinning ps every second. The scan takes ~50–80 ms on a typical box.

@Observable
@MainActor
final class RunningAgentScanner {

    struct Instance: Identifiable, Hashable {
        let id: String              // stable synthetic id: "{agentId}:{pid or bundleId}"
        let agentId: String         // matches AgentCatalog ids / HookInstaller.Agent rawValue
        let displayName: String     // "Copilot CLI", "Cursor", …
        let pid: Int32?             // nil for GUI apps we can't introspect
        let tty: String?            // "ttys003" — only for CLIs
        let cwd: String?            // last path component shown in UI
        let windowTitle: String?    // for GUI: current window title if available
        let startedAt: Date?

        var subtitle: String {
            var parts: [String] = []
            if let cwd, !cwd.isEmpty { parts.append((cwd as NSString).lastPathComponent) }
            if let tty, !tty.isEmpty { parts.append(tty) }
            if let windowTitle, !windowTitle.isEmpty, parts.isEmpty { parts.append(windowTitle) }
            return parts.joined(separator: " · ")
        }
    }

    private(set) var instances: [Instance] = []
    private(set) var lastScanAt: Date?

    // Which processes count as CLI agents. Match against `comm` (process name).
    private static let cliCommands: [String: String] = [
        "copilot":        "copilot-cli",
        "copilot-cli":    "copilot-cli",
        "claude":         "claude-code",
        "claude-code":    "claude-code",
        "codex":          "codex",
        "gemini":         "gemini",
    ]

    // GUI bundle ids we recognize.
    private static let guiBundles: [String: (id: String, name: String)] = [
        "com.todesktop.230313mzl4w4u92":  ("cursor", "Cursor"),
        "com.microsoft.VSCode":           ("vscode", "VS Code"),
        "dev.kiro.desktop":               ("kiro",   "Kiro"),
        "com.exafunction.windsurf":       ("windsurf", "Windsurf"),
        "com.trae.app":                   ("trae",   "Trae"),
        "dev.zed.Zed":                    ("zed",    "Zed"),
    ]

    // MARK: - Public

    func scan() {
        var out: [Instance] = []
        out.append(contentsOf: scanGUI())
        out.append(contentsOf: scanCLIs())
        // Stable sort: agent id then cwd then pid so the list doesn't shuffle.
        out.sort { lhs, rhs in
            if lhs.agentId != rhs.agentId { return lhs.agentId < rhs.agentId }
            let lc = lhs.cwd ?? "", rc = rhs.cwd ?? ""
            if lc != rc { return lc < rc }
            return (lhs.pid ?? 0) < (rhs.pid ?? 0)
        }
        self.instances = out
        self.lastScanAt = Date.now
    }

    // MARK: - GUI

    private func scanGUI() -> [Instance] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bid = app.bundleIdentifier,
                  let match = Self.guiBundles[bid] else { return nil }
            return Instance(
                id: "\(match.id):\(app.processIdentifier)",
                agentId: match.id,
                displayName: match.name,
                pid: app.processIdentifier,
                tty: nil,
                cwd: nil,          // would need AX to read the window title / project
                windowTitle: app.localizedName,
                startedAt: app.launchDate
            )
        }
    }

    // MARK: - CLIs

    private struct PSRow {
        let pid: Int32, ppid: Int32
        let tty: String
        let comm: String
        let command: String
    }

    private func scanCLIs() -> [Instance] {
        let rows = runPS()
        var out: [Instance] = []
        for row in rows {
            // Normalize comm: strip leading dash (login shell marker) and path.
            let commLeaf = (row.comm as NSString).lastPathComponent
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard let agent = Self.cliCommands[commLeaf] ?? matchCommand(row.command)
            else { continue }

            // Skip processes without a tty — those are daemons, not user sessions.
            guard !row.tty.isEmpty, row.tty != "??" else { continue }

            let cwd = lsofCWD(pid: row.pid)
            let name: String = {
                switch agent {
                case "copilot-cli": return "Copilot CLI"
                case "claude-code": return "Claude Code"
                case "codex":       return "Codex"
                case "gemini":      return "Gemini"
                default:            return agent
                }
            }()
            out.append(Instance(
                id: "\(agent):\(row.pid)",
                agentId: agent,
                displayName: name,
                pid: row.pid,
                tty: row.tty,
                cwd: cwd,
                windowTitle: nil,
                startedAt: nil
            ))
        }
        return out
    }

    // Match based on the full command line when `comm` alone isn't enough
    // (e.g., "node /usr/local/.../copilot-cli/bin/cli.js").
    private func matchCommand(_ cmd: String) -> String? {
        let lower = cmd.lowercased()
        if lower.contains("copilot-cli") || lower.contains("/copilot/") { return "copilot-cli" }
        if lower.contains("claude-code") { return "claude-code" }
        return nil
    }

    private func runPS() -> [PSRow] {
        // Use ww to avoid column truncation on long commands.
        guard let stdout = runSystem(
            "/bin/ps", args: ["-Ao", "pid=,ppid=,tty=,comm=,command="],
            timeout: 2.0
        ) else { return [] }
        var rows: [PSRow] = []
        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            // Tokenize by whitespace, but command can contain spaces — take
            // the first 4 tokens then treat the rest as command.
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            rows.append(PSRow(
                pid: pid,
                ppid: ppid,
                tty: String(parts[2]),
                comm: String(parts[3]),
                command: String(parts[4])
            ))
        }
        return rows
    }

    private func lsofCWD(pid: Int32) -> String? {
        guard let out = runSystem(
            "/usr/sbin/lsof",
            args: ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"],
            timeout: 0.5
        ) else { return nil }
        // Output shape: p<pid>\nf cwd\nn/Users/...
        for line in out.split(separator: "\n") {
            if line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    private func runSystem(_ path: String, args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        // Simple timeout loop (main actor → small budget).
        let deadline = Date(timeIntervalSinceNow: timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if p.isRunning { p.terminate(); return nil }
        guard let data = try? out.fileHandleForReading.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
