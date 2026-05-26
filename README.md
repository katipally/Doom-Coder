<div align="center">

<img src="assets/logo.png" alt="Doom Coder" width="400" />

# ⚡ Doom Coder

**Keep your Mac awake. Track your AI agents. Get notified on your iPhone.**

[![Release](https://img.shields.io/github/v/release/katipally/Doom-Coder?style=flat-square)](https://github.com/katipally/Doom-Coder/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue?style=flat-square)](#)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?style=flat-square)](#)

</div>

---

## What is Doom Coder?

A macOS menu bar app that does two things:

1. **Keeps your Mac awake** while long-running jobs (builds, downloads, agents) finish — without changing system settings.
2. **Tracks coding agents** (Claude Code, Cursor, VS Code Copilot, Copilot CLI, Windsurf, Codex CLI) and notifies you the moment they finish, fail, or need your attention — on your Mac and on your iPhone via the free **DoomCoder Companion** iOS app.

No accounts, no servers, no telemetry. Notifications travel through your own private iCloud container.

> **New to DoomCoder?** Every control in the app has a hover tooltip (the ⓘ icon) explaining what it does. See [docs/features.md](docs/features.md) for the full reference.

---

## Sleep Prevention

### Two modes

| Mode | What it does |
|---|---|
| **Screen On** | Display stays fully lit. Mac never sleeps. Good for glancing at progress. |
| **Screen Off** | Display sleeps after a short delay; Mac CPU stays awake. Saves power and reduces screen burn. |

Toggle from the menu bar, or globally with **⌥ Space**.

### Session timer

Auto-disable the sleep blocker after **1 / 2 / 4 / 8 hours** (or leave it running indefinitely). Tap a duration tile in the panel to set it — the elapsed time is shown live in the panel header.

### Screen Off re-arm

When using Screen Off mode, the display wakes when you move the mouse. DoomCoder will put it back to sleep automatically after a configurable idle interval (default: **5 minutes**). Adjust in **Configure → Settings → Screen Off**.

---

## How the sleep blocker works

DoomCoder holds an `IOPMAssertion` — the same kernel-level flag used by Amphetamine, Lungo, and `caffeinate`.

- ✅ **Zero CPU / < 10 MB RAM** — one flag in the kernel, no polling
- ✅ **Auto-released** on crash, quit, or disable
- ✅ **No system settings modified** — nothing to clean up
- ✅ **Session timer** — auto-disable after 1 / 2 / 4 / 8 hours
- ✅ **Launch at Login** (optional)
- ✅ **Sparkle auto-updates**
- ✅ **Global hotkey** (⌥ Space, rebindable)

---

## Agent tracking

### Supported agents

| Agent | Notification events | Config location |
|---|---|---|
| **Claude Code** | Completed, failed, waiting approval, session start, tool calls | `~/.claude/settings.json` |
| **Cursor** | Completed, failed, session start | `~/.cursor/hooks.json` |
| **VS Code Copilot** | Completed, failed, waiting input, session start | `~/.copilot/vscode-hooks/doomcoder.json` |
| **Copilot CLI** | Completed, failed, waiting approval, session start, tool calls | `~/.copilot/hooks/doomcoder.json` |
| **Windsurf** | Completed, failed, waiting input, session start | `~/.codeium/windsurf/hooks.json` |
| **Codex CLI** | Completed, failed, session start, tool calls | `~/.codex/hooks.json` |

VS Code hooks support multiple variants simultaneously: VS Code Stable, VS Code Insiders, VSCodium, Cursor, and Windsurf — choose which `settings.json` files to patch in **Configure → VS Code**.

### How hooks work

DoomCoder installs a lightweight `dc-hook` binary into each agent's hook configuration. When an agent fires a hook event, `dc-hook` writes a JSON envelope to a Unix socket that DoomCoder is listening on. The binary is stored in `~/Library/Application Support/DoomCoder/dc-hook` so it survives app relocations and Xcode rebuilds.

### Setting up hooks

1. Open the panel (click the menu bar icon or press **⌥ Space**).
2. Click **Configure** in the Agent Tracking card.
3. Select an agent in the sidebar.
4. Check prerequisites, then click **Install**.
5. The green health dot in the sidebar confirms events are flowing.

DoomCoder backs up your config before writing and can **Repair** hooks if they drift out of sync.

### Tracking toggles

Use **Track Agents** (accessible from the main panel) to:
- Enable or disable notifications **per agent** without uninstalling hooks.
- **Pause all notifications** temporarily (the Pause toggle resets when DoomCoder quits — it's in-memory only).

Events are still recorded in the local log even when an agent is paused or disabled.

---

## Notification channels

### macOS notifications

Standard macOS notification banners. Grant permission once; they work system-wide.

### iPhone & iPad (iCloud)

Requires the free **DoomCoder Companion** iOS app. Notifications mirror to your phone in 1–5 seconds via your private iCloud container — no third-party server, no tokens, no QR codes. Sign in to the same iCloud account on both devices.

### Notification event preferences

Choose exactly which events trigger a notification under **Configure → Notification Channels → Notify me when…**:

| Event | Default |
|---|---|
| Session completed | ✅ On |
| Errors | ✅ On |
| Permission requests | ✅ On |
| Agent responses | Off |
| Session started | Off |
| Sub-agent activity | Off |
| Tool usage | Off |

### Per-agent channel overrides

Each agent can override the global channel settings — for example, send Claude Code completions to your iPhone but skip VS Code Copilot. Enable **Use custom channels** in the agent's detail pane.

---

## iPhone companion

`DoomCoder Companion` (iOS 26+) mirrors every Mac notification to your iPhone in 1–5 seconds. It shows the same agent list, per-agent status, and a 7-day notification log. Install from the App Store and sign into the same iCloud account as your Mac — that's the entire setup.

[Get on the App Store](https://apps.apple.com/app/doomcoder-companion/id6772514212)

---

## Settings reference

| Setting | Default | Where |
|---|---|---|
| Launch at Login | Off | Configure → Settings → General |
| Global hotkey | ⌥ Space | Configure → Settings → General |
| Screen Off re-arm interval | 5 min | Configure → Settings → Screen Off |
| Auto-revert completed sessions | 30 s | Configure → Settings → Session Lifecycle |
| Redact prompt text in local history | On | Configure → Settings → Notifications & Privacy |

> Full details: [docs/features.md](docs/features.md)

---

## Logs & diagnostics

- **Live Events** — real-time event stream per agent in the Configure window.
- **Logs view** — browsable, filterable history of all hook events and notifications. Export to JSON or CSV. Accessible in Configure → Logs.
- **Raw log files** — stored in `~/Library/Logs/DoomCoder/`, retained for 7 days. Click **Reveal Logs** in Configure → Settings → Diagnostics.
- **Connection Doctor** — runs a synthetic test event end-to-end to verify the hook pipeline works.

---

## Install

Download the latest `.zip` from [Releases](https://github.com/katipally/Doom-Coder/releases/latest), unzip, drag `DoomCoder.app` to `/Applications`, and double-click to open.

DoomCoder is **signed with an Apple Developer ID and notarized by Apple** — no Gatekeeper prompts, no extra steps.

First launch: macOS may ask for Accessibility permission — only needed for the **⌥ Space** global shortcut. You can skip it if you don't need the hotkey.

---

## Build from source

```bash
git clone https://github.com/katipally/Doom-Coder.git
cd Doom-Coder
open DoomCoder.xcodeproj
```

Requires Xcode 26, macOS 26, Swift 6. Sparkle is pulled via SPM.

---

## License

MIT. See [LICENSE](LICENSE).

