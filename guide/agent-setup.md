# Agent Setup

DoomCoder 0.7 connects to your AI coding agents through **direct lifecycle events** instead of guessing from CPU and file writes. Each supported agent takes 5 seconds to set up.

Open **DoomCoder → Settings → Agent Bridge**. You'll see one card per agent.

---

## Tier 1: Shell hooks (Claude Code, Copilot CLI)

These are CLI agents that expose a hook mechanism.

### Claude Code

1. Install Claude Code (if you haven't): `npm install -g @anthropic-ai/claude-code`
2. In DoomCoder → Agent Bridge → **Claude Code** → click **Set Up**.
3. DoomCoder writes eight managed hook entries into `~/.claude/settings.json` (`SessionStart`, `SessionEnd`, `PreToolUse`, `PostToolUse`, `Notification`, `UserPromptSubmit`, `Stop`, `SubagentStop`). Your existing hooks are preserved and a timestamped backup is saved next to the file.
4. The status badge flips to **Connected** the next time you launch `claude`. No relaunch of Claude is required if it isn't already running.

### Copilot CLI

1. Install Copilot CLI (if you haven't): `gh extension install github/gh-copilot` or use the standalone `copilot` binary.
2. In DoomCoder → Agent Bridge → **Copilot CLI** → click **Set Up**.
3. DoomCoder installs `~/.copilot/extensions/doomcoder/hook.sh`. This shim forwards lifecycle signals to the bridge and never calls Copilot APIs or touches your token budget.

### What the hooks do

Each hook runs a one-line shell command — `/bin/sh ~/.doomcoder/hook.sh` — that reads the event JSON from stdin, packages it into a 30-byte message, and ships it to the local Unix socket at `~/.doomcoder/dc.sock`. If DoomCoder isn't running or the socket is unavailable, the hook exits 0 immediately so your agent is never blocked.

---

## Tier 2: MCP server (Cursor, Windsurf, VS Code, Gemini CLI, Codex)

These agents speak the [Model Context Protocol](https://modelcontextprotocol.io). DoomCoder installs itself as a tiny Python MCP server and exposes a single `dc` tool with a one-character `s` parameter.

Supported:
- **Cursor** — writes to `~/.cursor/mcp.json`
- **Windsurf** — writes to `~/.codeium/windsurf/mcp_config.json`
- **VS Code (MCP)** — writes to `~/Library/Application Support/Code/User/mcp.json`
- **Gemini CLI** — writes to `~/.gemini/settings.json`
- **Codex** — writes to `~/.codex/config.toml`

For each: click **Set Up**, then restart the agent. The status badge flips to **Connected** the first time the agent calls the `dc` tool.

### Token cost

Because the tool uses a one-character status code (`s/w/i/e/d`), the full call payload is under 140 tokens per state transition. For a 30-minute session with ~50 state changes, that's ≈ 7,000 tokens of overhead — pocket change compared to the agent's actual work.

### Prompting the agent to use it

Most MCP-aware agents notice new tools automatically. If yours doesn't, paste this system prompt fragment:

> You have a `dc` tool from the `doomcoder` MCP server. Call it at session start, whenever you're waiting on the user, whenever you hit an error, and at session end. The `s` argument is a single character: `s`=start, `i`=info, `w`=wait, `e`=error, `d`=done.

---

## Tier 3: Heuristic fallback

For any agent without hooks or MCP (Aider, Cline, generic shells), DoomCoder still falls back to the heuristic detector:

- Child-process count (≥ 2)
- Network receive-buffer delta (> 500 bytes over 2 s)
- FSEvents bursts in workspace storage (IDEs)

These still fire banners, but **only** when no Tier-1 or Tier-2 session is active. This prevents double-firing when an agent is connected through the bridge.

---

## Uninstalling

Each card has an **Uninstall** button that removes DoomCoder's managed entries only — every other hook or MCP server you installed yourself is left untouched. A backup is always kept; click **Restore Backup** to roll back.

---

## Verifying it works

1. Open Settings → Agent Bridge.
2. Look for the **Live sessions** card at the top. When you start a `claude` or `cursor` session, you should see a row appear within a second or two.
3. Click **Send Test Notification** on any card to inject a synthetic `waiting` event. A macOS banner + iPhone relay should fire immediately.

If nothing appears, see [troubleshooting.md](troubleshooting.md).
