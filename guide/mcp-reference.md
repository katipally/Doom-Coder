# MCP Reference

DoomCoder ships a tiny Python MCP server (`~/.doomcoder/mcp.py`, redeployed on every launch) that exposes a **single tool**:

```
dc(s: str, m: str = "")
```

where `s` is a 1-character status code and `m` is an optional ≤60-char message.

| `s` | Meaning |
|---|---|
| `s` | Session start — the agent began a new turn. |
| `w` | Waiting on the user (input required, dialog open, confirmation needed). |
| `e` | Unrecoverable error. |
| `d` | Session done — turn complete. |

On every call, the server forwards a compact JSON event to DoomCoder's local socket at `~/.doomcoder/dc.sock`. DoomCoder pipes it through `AgentStatusManager → NotificationManager → ntfy`.

## Transport

- **stdio** JSON-RPC (MCP protocol version `2024-11-05`).
- Spawned by the host agent via `/usr/bin/python3 ~/.doomcoder/mcp.py --agent <id> --install-id <uuid>`.
- On startup the server synthesizes an `mcp-hello` event over the socket so DoomCoder knows the agent loaded its config.

## The rules snippet

Every MCP install bundles a short, sentinel-bracketed instruction block into the agent's rules file. It tells the agent when to call `dc`:

- at session start,
- whenever input is needed,
- on unrecoverable error,
- at session end.

**Never** per-tool-use. **Never** narrate the call.

## Verification (two gates)

DoomCoder considers an MCP agent "configured" only after both:

1. **`mcp-hello`** — the agent spawned `mcp.py` on its own and the hello landed on the socket.
2. **First `dc(...)` call** — the agent honored the rules snippet.

The `Send Test` button in the detail pane runs a **self-test** (DoomCoder spawns `mcp.py` itself and drives the `initialize` RPC) to prove the script + socket pipeline is healthy, then reports the timestamp of the last real handshake/tool call from the actual agent — no synthetic events.

## Install Anywhere

For any MCP-capable client we don't ship a dedicated installer for (Zed, future IDEs, custom tooling), the Install Anywhere pane shows the ready-made JSON snippet with `command`, `args`, and the runtime-resolved script path. A "Your home" readout surfaces `NSHomeDirectory()` so the path is always verifiably yours — never hard-coded.

## Privacy

The MCP server never reads your source code, never talks to the cloud, never logs prompts. Its entire job is: receive a single-character status from the agent, emit a single JSON line to the local socket, exit.
