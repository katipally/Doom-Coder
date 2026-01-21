# Hooks Reference

This is the complete list of lifecycle events DoomCoder listens for, per agent, and what each one does.

---

## Transport

All hook events speak one format:

**Unix socket:** `~/.doomcoder/dc.sock` (mode 0600, owner-only)

**Payload:** one line of JSON per event, LF-terminated:

```json
{"src":"hook","agent":"claude-code","status":"w","sid":"<session-id>","cwd":"<path>","tool":"Read","msg":"waiting for user"}
```

**Fields:**
| key | required | meaning |
|-----|----------|---------|
| `src` | yes | `"hook"` (Tier 1) or `"mcp"` (Tier 2) or `"manual"` (test injection) |
| `agent` | yes | agent id — see `AgentCatalog` (`claude-code`, `copilot-cli`, `cursor`, …) |
| `status` | yes | one of `start` / `info` / `wait` / `error` / `done` (or single-char `s/i/w/e/d` over MCP) |
| `sid` | yes | session id; any string stable for the lifetime of one agent session |
| `cwd` | no | working directory; used to derive `repoName` in the UI |
| `tool` | no | name of the tool currently executing (`Read`, `Bash`, `Edit`, …) |
| `msg` | no | free-form message shown in the banner body |

**Dedup window:** 10 seconds per `(sid, status)`. Duplicate attention events inside the window are dropped.

**Never-blocking:** the hook shim calls `nc -U` (or a Python fallback) with a 1 s timeout and always exits 0. If DoomCoder is down, your agent is not affected.

---

## Claude Code

DoomCoder installs eight entries into `~/.claude/settings.json` under `.hooks`:

| Hook | When it fires | DoomCoder status |
|------|---------------|------------------|
| `SessionStart`      | Claude session opens                          | `start` |
| `UserPromptSubmit`  | User submits a prompt                         | `info` (progress) |
| `PreToolUse`        | Before any tool call                          | `info` (records tool name) |
| `PostToolUse`       | After any tool call                           | `info` |
| `Notification`      | Claude asks for input / permission / review   | `wait` |
| `Stop`              | Claude finishes turn                          | `done` |
| `SubagentStop`      | A sub-agent finishes                          | `info` |
| `SessionEnd`        | Session closes                                | `done` |

The command written for each is identical:

```sh
/bin/sh ${HOME}/.doomcoder/hook.sh claude-code <status>
```

All existing user hooks are preserved. On Uninstall, only the entries tagged with `"doomcoder_managed": true` are removed.

---

## Copilot CLI

DoomCoder writes a single extension script to `~/.copilot/extensions/doomcoder/hook.sh` and registers it in `~/.copilot/extensions/doomcoder/package.json`. The extension listens for:

| Copilot event | DoomCoder status |
|---------------|------------------|
| `session.start` | `start` |
| `tool.invoke`   | `info` |
| `prompt.wait`   | `wait` |
| `error`         | `error` |
| `session.end`   | `done` |

No tokens are consumed by the extension; it's a passive observer of lifecycle signals only.

---

## MCP agents (Cursor / Windsurf / VS Code / Gemini / Codex)

Instead of hooks, these agents call the **`dc`** tool exposed by `~/.doomcoder/mcp.py`:

```jsonc
{
  "name": "dc",
  "description": "Report agent status to DoomCoder.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "s":   { "type": "string", "enum": ["s","i","w","e","d"] },
      "msg": { "type": "string" }
    },
    "required": ["s"]
  }
}
```

The agent is expected to call `dc({s:"s"})` at session start, `dc({s:"w", msg:"waiting for confirmation"})` when blocked, and so on. The one-character `s` keeps the per-call token cost to roughly 140 tokens including schema and response.

---

## Test injection

Every card in Settings → Agent Bridge has a **Send Test** button that calls `AgentStatusManager.injectTest(agent:status:message:)` with `src = "manual"`. This is the same code path a real event would take, so if the test fires a banner, real events will too.
