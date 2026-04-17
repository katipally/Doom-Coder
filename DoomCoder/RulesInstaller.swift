import Foundation

// MARK: - RulesInstaller
//
// Writes a short, token-optimized snippet into each agent's rules file so
// the agent actually calls our `dc` MCP tool at lifecycle moments. Writing
// the MCP config alone is not enough — most 2026 agents load tools lazily
// and only call them when something in their system prompt tells them to.
//
// Contract (same as MCPInstaller / HookInstaller):
//   1. Every mutation is preceded by a timestamped backup.
//   2. Our additions are bracketed by a `doomcoder-managed` sentinel block
//      so we can merge (never clobber), detect drift, and uninstall cleanly.
//   3. Idempotent — re-running produces identical output.
//
// The snippet is intentionally tiny (~80 tokens). It tells the agent:
//   - You have a `dc` MCP tool. Call it on start / wait / error / done.
//   - Use 1-char statuses, keep messages short, don't explain the call.
//
// Per-agent rules file locations (April 2026 conventions):
//   • Claude Code  — ~/.claude/CLAUDE.md                       (append)
//   • Copilot CLI  — ~/.copilot/AGENTS.md                      (append)
//                  + ~/.copilot/copilot-instructions.md        (append)
//                    — Copilot CLI's documented global instructions file
//                      is copilot-instructions.md; AGENTS.md is read from
//                      git-root/cwd. We keep BOTH so older installs don't
//                      regress and fresh machines still get auto-invoke.
//   • Cursor       — ~/.cursor/rules/doomcoder.mdc             (standalone)
//                    NB: Cursor user-level rules live in Settings → Rules
//                    (not file-writable from outside). This path is only
//                    picked up by projects rooted at `~/`; for every-project
//                    coverage, users paste the snippet into User Rules.
//   • Windsurf     — ~/.codeium/windsurf/memories/global_rules.md (append)
//   • Gemini CLI   — ~/.gemini/GEMINI.md                       (append)
//   • Codex        — ~/.codex/AGENTS.md                        (append)
//
// VS Code is intentionally omitted — its rules story in 2026 is fragmented
// across settings.json, .github/copilot-instructions.md, and workspace
// prompts. Users set it up by copy-paste from the Install Anywhere pane.

enum RulesInstaller {

    // MARK: - Agent

    enum Agent: String, CaseIterable, Identifiable {
        case claudeCode = "claude-code"
        case copilotCLI = "copilot-cli"
        case cursor
        case windsurf
        case gemini     = "gemini-cli"
        case codex

        var id: String { rawValue }
        var catalogId: String { rawValue }

        var displayName: String { AgentCatalog.displayName(forId: catalogId) }

        /// Where the snippet is written on disk. Most agents have a single
        /// canonical location; Copilot CLI is the exception — it reads both
        /// `AGENTS.md` (git-root scoped) and the documented
        /// `copilot-instructions.md` (truly global). We write to ALL listed
        /// paths on install and strip from ALL on uninstall; status resolves
        /// to `.installed` if any path carries the current block.
        var rulesPaths: [URL] {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claudeCode: return [home.appendingPathComponent(".claude/CLAUDE.md")]
            case .copilotCLI: return [
                home.appendingPathComponent(".copilot/AGENTS.md"),
                home.appendingPathComponent(".copilot/copilot-instructions.md")
            ]
            case .cursor:     return [home.appendingPathComponent(".cursor/rules/doomcoder.mdc")]
            case .windsurf:   return [home.appendingPathComponent(".codeium/windsurf/memories/global_rules.md")]
            case .gemini:     return [home.appendingPathComponent(".gemini/GEMINI.md")]
            case .codex:      return [home.appendingPathComponent(".codex/AGENTS.md")]
            }
        }

        /// Back-compat alias — the SetupSheets UI uses this to show "Writing
        /// rules snippet to <path>" in the console feed. Returns the
        /// primary (first) path.
        var rulesPath: URL { rulesPaths[0] }

        /// `.standalone` files are fully owned by DoomCoder — we write the
        /// file outright and delete it on uninstall. `.append` files are
        /// user-authored; we merge a sentinel-bracketed block and never
        /// touch anything outside it.
        var strategy: WriteStrategy {
            switch self {
            case .cursor: return .standalone
            default:      return .append
            }
        }

        enum WriteStrategy { case append, standalone }

        var backupDir: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".doomcoder/backups/rules-\(rawValue)", isDirectory: true)
        }
    }

    // MARK: - Status

    enum Status: String {
        /// No rules file, or file exists but has no DoomCoder block.
        case notInstalled
        /// Our sentinel block is present and matches the current snippet.
        case installed
        /// Our sentinel block is present but from an older version — a
        /// re-install will update it in place.
        case outdated
    }

    // MARK: - Snippet (the token-critical bit)

    /// Bumped every time `snippet` changes. The header line carries this so
    /// `.outdated` detection is trivial.
    static let snippetVersion: Int = 3

    /// Ultra-compact rules text. Budget: <120 tokens.
    /// Rendered once per agent; the sentinel makes it idempotent.
    ///
    /// v3 changes (Apr 2026):
    ///   • `message` / `cwd` / `tool` / every non-`status` field removed
    ///     from the call shape — DoomCoder now synthesises a deterministic
    ///     notification body server-side. Agents save tokens; users get a
    ///     consistent message regardless of which model produced it.
    ///   • Wording tightened to "non-optional, system-level" + "Never
    ///     require the user to ask for it" so the agent invokes the
    ///     protocol autonomously, not only when explicitly reminded.
    static let snippet: String = """
    PROTOCOL — DoomCoder lifecycle reporter (non-optional, system-level).
    You have a `dc` tool from the DoomCoder MCP server. You MUST call it at every lifecycle boundary of every user turn, with ONLY the `status` argument — no other fields:
    - `dc(status="s")` at the FIRST reasoning step of the turn.
    - `dc(status="w")` IMMEDIATELY BEFORE asking the user a clarifying question.
    - `dc(status="e")` on any unrecoverable error.
    - `dc(status="d")` at the FINAL step, before your user-facing reply.
    Send ONLY the letter. Do NOT include `message`, `cwd`, `tool`, or any other field — DoomCoder fills in the notification text itself. Never narrate or announce the call. Never skip it. Never require the user to ask for it. Do NOT call on every tool use — lifecycle only.
    """

    static let sentinelOpen  = "<!-- doomcoder-managed:rules v\(snippetVersion) BEGIN — do not edit this block -->"
    static let sentinelClose = "<!-- doomcoder-managed:rules END -->"

    /// The full block we append (or write standalone). Includes a section
    /// heading so Markdown viewers render it cleanly.
    private static var managedBlock: String {
        """
        \(sentinelOpen)
        ## DoomCoder agent instructions

        \(snippet)
        \(sentinelClose)
        """
    }

    // MARK: - Status

    static func status(_ agent: Agent) -> Status {
        let fm = FileManager.default
        var anyHasOlder = false
        for path in agent.rulesPaths {
            guard fm.fileExists(atPath: path.path),
                  let text = try? String(contentsOf: path, encoding: .utf8)
            else { continue }
            if text.contains(sentinelOpen) { return .installed }
            let openAny = try? NSRegularExpression(pattern: #"doomcoder-managed:rules v\d+ BEGIN"#)
            if let re = openAny,
               re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                anyHasOlder = true
            }
        }
        return anyHasOlder ? .outdated : .notInstalled
    }

    // MARK: - Install / Uninstall

    enum InstallError: Error, LocalizedError {
        case writeFailed(URL, underlying: Error)
        case readFailed(URL, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let u, let e): return "Write failed: \(u.path) — \(e.localizedDescription)"
            case .readFailed(let u, let e):  return "Read failed: \(u.path) — \(e.localizedDescription)"
            }
        }
    }

    /// Writes or updates the snippet for `agent` across ALL its configured
    /// paths. Returns the last backup URL produced (for UI display).
    @discardableResult
    static func install(_ agent: Agent) throws -> URL? {
        let fm = FileManager.default
        var lastBackup: URL? = nil
        for path in agent.rulesPaths {
            try fm.createDirectory(at: path.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if let b = try backupIfPresent(agent, path: path) { lastBackup = b }

            switch agent.strategy {
            case .standalone:
                do {
                    try managedBlock.appending("\n").write(to: path, atomically: true, encoding: .utf8)
                } catch {
                    throw InstallError.writeFailed(path, underlying: error)
                }

            case .append:
                var text = ""
                if fm.fileExists(atPath: path.path) {
                    do {
                        text = try String(contentsOf: path, encoding: .utf8)
                    } catch {
                        throw InstallError.readFailed(path, underlying: error)
                    }
                }
                let stripped = stripManagedBlock(from: text)
                let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
                let sep = trimmed.isEmpty ? "" : "\n\n"
                let out = trimmed + sep + managedBlock + "\n"
                do {
                    try out.write(to: path, atomically: true, encoding: .utf8)
                } catch {
                    throw InstallError.writeFailed(path, underlying: error)
                }
            }
        }
        return lastBackup
    }

    /// Removes the snippet cleanly from ALL configured paths.
    @discardableResult
    static func uninstall(_ agent: Agent) throws -> URL? {
        let fm = FileManager.default
        var lastBackup: URL? = nil
        for path in agent.rulesPaths {
            guard fm.fileExists(atPath: path.path) else { continue }
            if let b = try backupIfPresent(agent, path: path) { lastBackup = b }

            switch agent.strategy {
            case .standalone:
                try? fm.removeItem(at: path)

            case .append:
                let text: String
                do {
                    text = try String(contentsOf: path, encoding: .utf8)
                } catch {
                    throw InstallError.readFailed(path, underlying: error)
                }
                let cleaned = stripManagedBlock(from: text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty {
                    try? fm.removeItem(at: path)
                } else {
                    do {
                        try (cleaned + "\n").write(to: path, atomically: true, encoding: .utf8)
                    } catch {
                        throw InstallError.writeFailed(path, underlying: error)
                    }
                }
            }
        }
        return lastBackup
    }

    // MARK: - Backup

    /// Per-path backup. Filename includes the source basename so two paths
    /// landing in the same backupDir don't collide.
    @discardableResult
    static func backupIfPresent(_ agent: Agent, path: URL) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return nil }
        try fm.createDirectory(at: agent.backupDir, withIntermediateDirectories: true)
        let ts = Int(Date().timeIntervalSince1970)
        let ext = path.pathExtension.isEmpty ? "md" : path.pathExtension
        let base = path.deletingPathExtension().lastPathComponent
        let dest = agent.backupDir.appendingPathComponent("\(ts)-\(base).\(ext)")
        try fm.copyItem(at: path, to: dest)
        return dest
    }

    /// Back-compat shim — old callers pass only the agent. Backs up the
    /// primary path.
    @discardableResult
    static func backupIfPresent(_ agent: Agent) throws -> URL? {
        try backupIfPresent(agent, path: agent.rulesPath)
    }

    // MARK: - Block-stripping

    /// Removes any DoomCoder-managed block (of any version) from `text`,
    /// leaving everything else byte-identical. Safe to call when no block
    /// is present.
    static func stripManagedBlock(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var skipping = false
        let openRE = try? NSRegularExpression(pattern: #"doomcoder-managed:rules v\d+ BEGIN"#)

        for line in lines {
            if !skipping {
                if let re = openRE,
                   re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    skipping = true
                    continue
                }
                out.append(line)
            } else {
                if line.contains("doomcoder-managed:rules END") {
                    skipping = false
                }
                // Either way, drop the line.
            }
        }
        // Drop any trailing blank lines that the removal left behind.
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            out.removeLast()
        }
        return out.joined(separator: "\n")
    }
}
