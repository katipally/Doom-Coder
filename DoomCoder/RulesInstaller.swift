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
// The snippet is intentionally tiny (~60 tokens). It tells the agent:
//   - You have a `dc` MCP tool. Call `dc(d)` EXACTLY ONCE at the end of
//     your reply, after all tool work and final text are produced.
//   - Call `dc(w)` once before asking the user a clarifying question.
//   - Don't fire on every tool use. Don't fire repeatedly in one turn.
//
// Each `dc` call costs roughly ~50 tokens (tool schema + args + result).
// One call per reply is the target.
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
//
// v1.8.3 scope: Claude Code, Copilot CLI, Cursor only. Windsurf / Gemini /
// Codex / VS Code are handled via the Install Anywhere (custom MCP) pane,
// which shows the same snippet + MCP config JSON for manual paste. The
// narrower scope reduced flaky per-agent support: each one evolves its
// rules-file story independently, which made us promise things we couldn't
// keep in three places at once.

enum RulesInstaller {

    // MARK: - Agent

    // v1.8.3: scope reduced to Cursor, Claude Code, Copilot CLI.
    // Windsurf / Gemini / Codex cases were removed — they had high support
    // cost (each one's rules file/MCP config drifted independently) and low
    // usage. Users on those stacks now follow the generic "Install Anywhere"
    // (custom MCP) instructions, which let them paste the snippet anywhere.
    enum Agent: String, CaseIterable, Identifiable {
        case claudeCode = "claude-code"
        case copilotCLI = "copilot-cli"
        case cursor

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
    static let snippetVersion: Int = 6

    /// Ultra-compact rules text. Budget: ~60 tokens. One `dc` call per reply.
    ///
    /// v6 changes (Apr 2026):
    ///   • Single focus: one `dc("d")` at the true end of a reply. Period.
    ///     v5's "EXACTLY ONCE per reply" framing was still misread by
    ///     Cursor's tool-result loop as "fire once per loop iteration",
    ///     producing 2-3 banners per reply. v6 tells the agent flatly:
    ///     fire only when the reply is complete and no more tool calls or
    ///     text will follow. Server-side debounce (AgentStatusManager) is
    ///     a safety net against remaining stragglers.
    ///   • `dc("w")` kept but de-emphasised; the server now drops duplicate
    ///     `w` events from the same agent within 15s and drops any `w`
    ///     while the user is actively typing/clicking, so a noisy agent
    ///     can't spam the user.
    ///   • No more "EXACTLY" / "ALWAYS" / "REQUIRED" — the LLM community
    ///     finding (Apr 2026) is these turn lifecycle guidance into a
    ///     per-step compulsion. Softer "once, at the end" performs better.
    static let snippet: String = """
    DoomCoder lifecycle reporter (macOS notification bridge). You have a `dc` MCP tool. Send ONLY the `status` argument; DoomCoder writes the notification text itself.

    When your reply is fully complete — after all tool calls AND after your final user-facing text — call `dc(status="d")` exactly once, as the very last thing. This fires a single "task done" notification on the user's Mac or phone.

    If you need to stop mid-turn to ask the user a question, call `dc(status="w")` once right before the question, then finish later with one `dc("d")` after the user replies.

    Do not call `dc` during tool loops, between thinking steps, from sub-agents, or more than once per reply. Do not pass any other argument. Do not mention the call. When unsure, skip `w` entirely — one `d` per reply is the whole protocol.
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
