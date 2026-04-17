# Agent Setup

DoomCoder tracks your AI coding agents through **deterministic lifecycle events** — no CPU polling, no heuristics. As of v0.8 every supported agent uses the **Model Context Protocol (MCP)**, except for Claude Code which keeps a shell-hook installer for backwards compatibility while its MCP path is adopted.

Open **DoomCoder → Agents** and pick an agent. Setup is a three-step sheet: Explain → Install → Verify.

---

## The three-part MCP contract

For every MCP agent, DoomCoder installs **three** things and will not flip to "Connected" until all three are confirmed:

1. **MCP config entry** — a `doomcoder` server block in the agent's config file (`~/.cursor/mcp.json`, `~/.claude.json`, `~/.copilot/mcp-config.json`, etc.).
2. **Rules snippet** — a short block added to the agent's rules file (`CLAUDE.md`, `~/.cursor/rules/doomcoder.mdc`, `AGENTS.md`, `GEMINI.md`, …) that tells the agent *when* to call DoomCoder's `dc` tool. Without this step, the MCP server sits idle.
3. **Two-gate verification** — Setup only turns green after:
   - `mcp-hello` arrives on `~/.doomcoder/dc.sock` (proves the config was loaded), **and**
   - a real `dc(...)` tool call arrives (proves the rules were read and honored).

All writes are sentinel-bracketed (`<!-- doomcoder-managed:rules v1 BEGIN ... -->`) and a timestamped backup is kept next to every file DoomCoder touches. Uninstall strips the block and restores the rest unchanged.

## Supported agents

| Agent | MCP config | Rules file |
|---|---|---|
| Cursor | `~/.cursor/mcp.json` | `~/.cursor/rules/doomcoder.mdc` (standalone) |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` | `~/.codeium/windsurf/memories/global_rules.md` |
| VS Code (MCP) | `~/Library/Application Support/Code/User/mcp.json` | (user-global instructions) |
| Claude Code | `~/.claude.json` (+ legacy hook install) | `~/.claude/CLAUDE.md` |
| Copilot CLI | `~/.copilot/mcp-config.json` | `~/.copilot/AGENTS.md` |
| Gemini CLI | `~/.gemini/settings.json` | `~/.gemini/GEMINI.md` |
| Codex | `~/.codex/config.toml` | `~/.codex/AGENTS.md` |

Anything not in this list: use the **Install Anywhere** tab for a generic MCP snippet.

## Token cost

The `dc` tool uses a single-character status (`s`=start, `w`=wait, `e`=err, `d`=done) plus an optional ≤60-char message. The rules snippet is under 150 tokens. A 30-minute session with ~20 state transitions costs **under 5k tokens of overhead** — negligible.

## Verifying

Each agent card exposes a **Send Test** button. For MCP agents this runs a real self-test (DoomCoder spawns its own copy of `mcp.py` and drives the MCP `initialize` handshake) plus shows the timestamp of the last real handshake and last `dc` call observed from the actual agent. No synthetic events.

## Uninstalling

The **Uninstall** button strips only DoomCoder's managed blocks from config + rules files. Backups are kept. Your own rules and MCP servers are never touched.

## Troubleshooting

See [troubleshooting.md](troubleshooting.md). Most common issue: an agent that was already running when you pressed Set Up. Fully quit (Cmd+Q for GUI apps, `exit` for CLIs) and start it fresh — MCP configs are read at process start.
