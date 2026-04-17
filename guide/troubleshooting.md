# Troubleshooting

Common issues with DoomCoder 1.8 and how to fix them.

---

## Agent tracking

### "Bridge offline" in Configure Agents

DoomCoder couldn't open the Unix socket at `~/.doomcoder/dc.sock`.

1. Quit DoomCoder completely (menu bar → Quit).
2. Delete any stale socket: `rm ~/.doomcoder/dc.sock`.
3. Relaunch DoomCoder.

If it still fails, check the error message under the "Bridge offline" badge — it's usually a filesystem permission problem on `~/.doomcoder/`.

### An agent is set up, but status stays "Not set up"

The status flips only after two gates:

1. `mcp-hello` arrives (proves the agent loaded the `doomcoder` MCP server).
2. A real `dc(...)` tool call arrives (proves the rules were honored).

Fully quit and relaunch the agent after pressing Set Up — MCP configs are loaded once at process start.

### "dc tool not found" inside the agent

- Did you restart the agent after clicking Set Up? MCP servers are loaded only on agent startup.
- Check that `~/.doomcoder/mcp.py` exists and is executable.
- For Cursor/Windsurf/VS Code, verify the `mcp.json` file contains a `doomcoder` server entry. Re-click Set Up to overwrite it.
- For Codex, check `~/.codex/config.toml` for a `[mcp_servers.doomcoder]` section.

### Cursor only calls `dc` when I mention DoomCoder by name

Cursor's per-workspace `.cursor/rules/doomcoder.mdc` only auto-attaches when a workspace is rooted at your home folder. The fix is to paste DoomCoder's snippet into **Cursor → Settings → Rules → User Rules** — it then applies to every project.

The Setup → Install step for Cursor has a **Copy snippet** button plus **Open Cursor** deep-link for exactly this.

---

## iPhone notifications (ntfy)

### ntfy notifications don't arrive on my phone

1. Install the **ntfy** app from the App Store.
2. Tap **Subscribe to topic** in the app.
3. Copy the URL from DoomCoder → iPhone → ntfy section. It looks like `https://ntfy.sh/doom-<random>`.
4. Paste the topic name (the part after `ntfy.sh/`) into the app.
5. Send a test from DoomCoder. If nothing arrives, check the delivery log for the HTTP status.

### Delivery log shows "Channel disabled"

You hit Send Test while the ntfy toggle was off. Turn it on first.

---

## Tracking notifications

### Banner never fires for an agent task

- Open the menu bar → **Track** submenu and confirm the agent is checked. Only tracked agents fire notifications.
- Confirm the agent is configured (Configure Agents → green badge).
- Confirm your notification banner isn't blocked by Do Not Disturb / Focus.
- Open **System Settings → Notifications → DoomCoder** and confirm alerts are enabled.

### Too many banners

Each iPhone channel fires independently. Disable the channels you don't need in Settings → iPhone.

---

## Logs & diagnostics

DoomCoder doesn't write logs to disk by default. To inspect what's happening:

1. Open **Console.app**.
2. Filter by process: `DoomCoder`.
3. Watch as you trigger events; `os_log` calls from the bridge and channels will show up in real time.

To dump the current socket state manually:

```sh
echo '{"src":"manual","agent":"cursor","status":"w","sid":"test-1","msg":"hello"}' \
  | nc -U ~/.doomcoder/dc.sock
```

If the Live sessions card adds a new row, the bridge is healthy.

---

## Still stuck?

Open an issue at https://github.com/katipally/Doom-Coder/issues/new and include:

1. macOS version.
2. DoomCoder version (About window).
3. Which agent(s) you're using.
4. What you see in Configure Agents.
5. Any relevant entries from the delivery log.
