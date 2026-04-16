# Troubleshooting

Common issues with DoomCoder 0.7 and how to fix them.

---

## Agent Bridge

### "Bridge offline" in Settings → Agent Bridge

DoomCoder couldn't open the Unix socket at `~/.doomcoder/dc.sock`.

1. Quit DoomCoder completely (menu bar → Quit).
2. Delete any stale socket: `rm ~/.doomcoder/dc.sock`.
3. Relaunch DoomCoder.

If it still fails, check the error message under the "Bridge offline" badge — it's usually a filesystem permission problem on `~/.doomcoder/`.

### Claude Code set up, but status stays "Not set up"

The status flips only when Claude Code actually sends its first event. Launch a `claude` session in a terminal and type anything; the badge should flip within a second.

If it still doesn't:

1. Reveal the settings file in Finder (the disclosure group has a button for it).
2. Confirm the `hooks` section contains entries with `"doomcoder_managed": true`.
3. Confirm `~/.doomcoder/hook.sh` exists and is executable: `ls -l ~/.doomcoder/hook.sh`.
4. Test the pipeline manually: `echo '{"status":"w"}' | /bin/sh ~/.doomcoder/hook.sh claude-code w` — this should show up in Live sessions.

### MCP agent says "dc tool not found"

- Did you restart the agent after clicking Set Up? MCP servers are loaded only on agent startup.
- Check that `~/.doomcoder/mcp.py` exists and is executable.
- For Cursor/Windsurf/VS Code, verify the `.mcp.json` file contains a `doomcoder` server entry. Re-click Set Up to overwrite it.
- For Codex, check `~/.codex/config.toml` for a `[mcp_servers.doomcoder]` section.

---

## iPhone notifications

### Reminders channel says "Permission needed"

Click **Grant Access**. If the system popup doesn't appear:

1. Open **System Settings → Privacy & Security → Reminders**.
2. Ensure **DoomCoder** is in the list and toggled on.
3. Return to DoomCoder → iPhone tab → click **Refresh** (the arrow button).

### iMessage says "Send failed"

Most common causes:

- **Not signed in to iMessage on your Mac.** Open Messages.app and sign in with your Apple ID.
- **Handle format wrong.** Use the exact format iMessage shows in a conversation header — e.g. `+14155551234` for phone, or `you@icloud.com` for Apple ID email. No spaces, no parentheses.
- **AppleEvents permission denied.** Open **System Settings → Privacy & Security → Automation → DoomCoder** and ensure **Messages** is toggled on.
- **Receiving iPhone is offline.** iMessage queues but delivery can stall. Try texting yourself first to verify the pipeline.

### ntfy notifications don't arrive on my phone

1. Install the **ntfy** app from the App Store.
2. Tap **Subscribe to topic** in the app.
3. Copy the URL from DoomCoder → iPhone → ntfy section. It looks like `https://ntfy.sh/doom-<random>`.
4. Paste the topic name (the part after `ntfy.sh/`) into the app.
5. Send a test from DoomCoder. If nothing arrives, check the delivery log in DoomCoder for the HTTP status.

### Delivery log shows "Channel disabled"

You hit Send Test on a channel whose toggle is off. Turn it on first.

---

## False positives / false negatives

### Banner never fires for an AI task

- First, confirm the app is connected via the bridge (Agent Bridge tab → Connected badge). If it is, the heuristic is suppressed — the bridge path should fire instead.
- Check that your notification banner isn't being blocked by Do Not Disturb / Focus.
- Open **System Settings → Notifications → DoomCoder** and confirm alerts are enabled.

### Too many banners for one task

v0.8 added a 10-second de-dup window per session per status. If you still get duplicates:

- Check if the agent is installed via both a hook **and** an MCP server (rare — we warn in Settings). Uninstall one.
- Each iPhone channel fires independently. Disable the channels you don't need.

### Heuristic still fires banners when bridge is active

This shouldn't happen in v0.8 (Tier-3 demotion). If it does:

- Quit and relaunch DoomCoder to reset the suppression wiring.
- Report it: the `shouldSuppressHeuristic` closure didn't trigger, which is a bug.

---

## Logs & diagnostics

DoomCoder doesn't write logs to disk by default. To inspect what's happening:

1. Open **Console.app**.
2. Filter by process: `DoomCoder`.
3. Watch as you trigger events; `os_log` calls from the bridge and channels will show up in real time.

To dump the current socket state manually:

```sh
echo '{"src":"manual","agent":"claude-code","status":"w","sid":"test-1","msg":"hello"}' \
  | nc -U ~/.doomcoder/dc.sock
```

If the Live sessions card adds a new row, the bridge is healthy.

---

## Still stuck?

Open an issue at https://github.com/katipally/Doom-Coder/issues/new and include:

1. macOS version.
2. DoomCoder version (About window).
3. Which agent(s) you're using.
4. What you see in Settings → Agent Bridge.
5. Any relevant entries from the delivery log.
