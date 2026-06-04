<div align="center">

<img src="assets/logo.png" alt="Doom Coder" width="400" />

# DoomCoder

**Keep your Mac awake. Track your AI agents. Get notified on your iPhone.**

[![Release](https://img.shields.io/github/v/release/katipally/Doom-Coder?style=flat-square)](https://github.com/katipally/Doom-Coder/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue?style=flat-square)](#)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?style=flat-square)](#)

</div>

---

## What is DoomCoder?

A macOS menu bar app that does two things:

1. **Keeps your Mac awake** while long-running jobs (builds, downloads, agents) finish, without changing any system settings.
2. **Tracks coding agents** (Claude Code, Cursor, VS Code Copilot, Copilot CLI, Windsurf, Codex CLI) and notifies you the moment they finish, fail, or need your attention, on your Mac and on your iPhone via the free **DoomCoder Companion** iOS app.

No accounts, no servers, no telemetry. Notifications travel through your own private iCloud container.

> **New to DoomCoder?** Every control in the app has a hover tooltip (the ⓘ icon) explaining what it does. See [docs/features.md](docs/features.md) for the full reference.

---

## Sleep Prevention

### Three keep-awake modes

| Mode | What it does |
|---|---|
| **Off** | macOS manages sleep normally. DoomCoder is running but holds no assertion. |
| **On** | Always holds the sleep assertion. Sub-option: **Screen On** (display stays lit) or **Screen Off** (display dims; CPU stays awake). |
| **Auto** | Caffeine-style smart mode. Holds the sleep assertion while **either** a tracked agent is actively working **or** you are at the keyboard/mouse. Releases 10 minutes after both signals go silent. Also supports **Snooze** (15 min / 1 hour / until you turn it off) for cases where you want to override Auto temporarily. Respects per-agent tracking toggles. |

Switch modes from the menu bar panel. **Option Space** opens the panel.

### Screen modes (when Keep-Awake is On)

| Mode | What it does |
|---|---|
| **Screen On** | Display stays fully lit. Mac never sleeps. Good for glancing at progress. |
| **Screen Off** | Display sleeps after a short delay; Mac CPU stays awake. Saves power and reduces screen burn. |

### Session timer (when Keep-Awake is On)

Auto-disable the sleep blocker after **1 / 2 / 4 / 8 hours** (or leave it running indefinitely). Tap a duration tile in the panel to set it.

### Screen Off re-arm

When using Screen Off mode, the display wakes when you move the mouse. DoomCoder will put it back to sleep automatically after a configurable idle interval (default: **10 minutes**). Adjust in **Configure > Settings > Screen Off**.

### Auto mode snooze (v2.6+)

When Auto is the active mode, a **Snooze** pill appears below the Off/On/Auto segmented control. Tap it to override Auto and hold the Mac awake for:

- **15 minutes** — a quick coffee break
- **1 hour** — a meeting or phone call
- **Until I turn it off** — indefinite, like Caffeine

While snoozed, the panel shows a countdown badge and the menu-bar icon swaps to a `moon.zzz.fill`. Cancel the snooze any time from the same menu or from the iOS companion. The iOS companion mirrors the snooze state with a live countdown banner.

---

## How the sleep blocker works

DoomCoder holds an `IOPMAssertion`, the same kernel-level flag used by Amphetamine, Lungo, and `caffeinate`.

- Zero CPU / less than 10 MB RAM -- one flag in the kernel, no polling
- Auto-released on crash, quit, or disable
- No system settings modified -- nothing to clean up
- Session timer -- auto-disable after 1 / 2 / 4 / 8 hours
- Launch at Login (optional)
- Sparkle auto-updates
- Global hotkey (Option Space, rebindable)

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

VS Code hooks support multiple variants simultaneously: VS Code Stable, VS Code Insiders, VSCodium, Cursor, and Windsurf -- choose which `settings.json` files to patch in **Configure > VS Code**.

### How hooks work

DoomCoder installs a lightweight `dc-hook` binary into each agent's hook configuration. When an agent fires a hook event, `dc-hook` writes a JSON envelope to a Unix socket that DoomCoder is listening on. The binary is stored in `~/Library/Application Support/DoomCoder/dc-hook` so it survives app relocations and Xcode rebuilds.

### Setting up hooks

1. Open the panel (click the menu bar icon or press **Option Space**).
2. Click **Configure** in the Agent Tracking card.
3. Select an agent in the sidebar.
4. Check prerequisites, then click **Install**.
5. The green health dot in the sidebar confirms events are flowing.

DoomCoder backs up your config before writing and can **Repair** hooks if they drift out of sync.

### Tracking toggles

Use **Track Agents** (accessible from the main panel) to:
- Enable or disable notifications per agent without uninstalling hooks.
- **Pause all notifications** temporarily (the Pause toggle resets when DoomCoder quits -- it is in-memory only).

Events are still recorded in the local log even when an agent is paused or disabled.

---

## Connections

The **Connections** tab (Configure window) is where notifications get delivered and where you see the devices connected to this Mac.

### Connected devices

Each iPhone or iPad running the DoomCoder Companion publishes a periodic presence heartbeat to your private iCloud container. The Mac shows each device as **Connected** when seen within the last 10 minutes, or **Last seen X ago** otherwise — symmetric to how the companion shows your Mac's status. When nothing has checked in, a **Set up iPhone or iPad** button links to the App Store.

### macOS notifications

Standard macOS notification banners. Grant permission once; they work system-wide.

### iPhone and iPad (iCloud)

Requires the free **DoomCoder Companion** iOS app. Notifications mirror to your phone in 1-5 seconds via your private iCloud container -- no third-party server, no tokens, no QR codes. Sign in to the same iCloud account on both devices.

### Notification event preferences

Each agent's detail pane has a **"What you'll be notified about"** card. Tap **Edit** to choose exactly which events alert you, grouped for clarity:

| Group | Categories | Default |
|---|---|---|
| **Important** | Completed, Failed, Waiting for approval, Waiting for input | On |
| **Activity** | Session started, Tool calls, Sub-agent activity, File edits, Thinking, Prompt sent | Off |
| **Housekeeping** | Context compaction, Background tasks | Off |

Only the categories an agent actually emits are shown, so you never see a toggle that can't fire. Permission/approval categories expand to a per-tool palette so you can, for example, be alerted before shell commands but not before file reads.

### No more auto-accept spam

Copilot CLI, Cursor, and Windsurf emit a *permission* hook **before** their own allowlist decides to auto-approve an action — so a naive watcher would alert you for tools that were never actually blocked. DoomCoder waits a short **approval debounce window** (default 0.8s, adjustable 0.5-3s under **Configure > Settings**) for proof the tool ran; only genuinely-blocking requests produce an alert. Live status in the menu bar and Dynamic Island is unaffected and always instant. Agents with reliable hooks (Claude Code, VS Code Copilot, Codex) alert immediately with no added latency.

### Connections are global

One global **mac + iPhone** channel setting applies to every agent. (Per-agent channel overrides were removed — they added complexity without clear benefit. Per-agent control now lives in the *categories* card above.)

---

## iPhone and iPad companion

**DoomCoder Companion** (iOS 26+) is a standalone app, fully usable on first launch with no setup required. No Mac connection, no API key, no account.

### What works with zero setup

**Prompts tab** -- a chat-style prompt workspace. Type a prompt, hit send, and the AI rewrites it into a clear, structured version. Conversation history is saved automatically; use the History button in the toolbar to switch between sessions. The Library button opens a curated collection of ready-made development prompts (write tests, refactor, explain errors, code review, debug, docstrings, commit messages, SQL, API design, security review, and more) that you can copy or open in the chat.

**Notes tab** -- on-device notes with title, body, inline task checklists, reminders (local notifications), pinning, and search. Notes can be turned into a prompt with one tap. Works entirely on-device, no network required.

**Prompt Enhance (AI)** -- rewrites your draft prompt using Apple's on-device model (no text leaves your device) or your own API key from OpenAI, Anthropic, or similar providers (BYOK). Enhance is optional; the rest of the app works without it.

### What you get when connected to a Mac

Pair by signing into the same iCloud account on both devices. Once paired, the **Dashboard** tab mirrors the Mac panel in real time:
- Live agent list with status (running, waiting, idle, failed)
- 7-day notification log with full event detail

The iOS app is **read-only**: it mirrors the Mac's state but does not send any commands back. Use the Mac directly to change keep-awake, master switch, or sleep settings.

Notifications arrive on your iPhone within 1-5 seconds of the agent event, via your private iCloud container.

### Pairing a Mac on a different Apple ID (v2.7+)

If your iPhone and Mac are on different Apple IDs, you can still pair them with a one-time QR code:

1. On the Mac, open **Configure ▸ Connections** and click **Add iPhone**. A QR code and a short pairing code appear.
2. On the iPhone, open DoomCoder Companion and tap **Add a Mac** in the Dashboard tab (or use the "Add a Mac" link in the empty state). Scan the QR code.
3. iOS shows its standard share-acceptance sheet. Accept, and the new Mac appears in the Devices section at the top of the Dashboard.

You can pair several Macs from one iPhone (one per Apple ID), and one Mac can pair with several iPhones. Each Mac shows up in the Devices section on the iPhone; if you have more than one, a segmented picker lets you focus on a single Mac.

Removing a Mac on the iPhone wipes that Mac's local cache (status, agents, notifications) on the iPhone only; the Mac keeps its own data and the iCloud share until you revoke it from System Settings.

[Get on the App Store](https://apps.apple.com/app/doomcoder-companion/id6772514212)

---

## Settings reference

| Setting | Default | Where |
|---|---|---|
| Launch at Login | Off | Configure > Settings > General |
| Global hotkey | Option Space | Configure > Settings > General |
| Screen Off re-arm interval | 5 min | Configure > Settings > Screen Off |
| Auto-revert completed sessions | 30 s | Configure > Settings > Session Lifecycle |
| Redact prompt text in local history | On | Configure > Settings > Notifications & Privacy |

Full details: [docs/features.md](docs/features.md)

---

## Logs and diagnostics

- **Live Events** -- real-time event stream per agent in the Configure window.
- **Logs view** -- browsable, filterable history of all hook events and notifications. Export to JSON or CSV. Accessible in Configure > Logs.
- **Raw log files** -- stored in `~/Library/Logs/DoomCoder/`, retained for 7 days. Click **Reveal Logs** in Configure > Settings > Diagnostics.
- **Connection Doctor** -- runs a synthetic test event end-to-end to verify the hook pipeline works.

---

## Install

Download the latest `.zip` from [Releases](https://github.com/katipally/Doom-Coder/releases/latest), unzip, drag `DoomCoder.app` to `/Applications`, and double-click to open.

DoomCoder is signed with an Apple Developer ID and notarized by Apple -- no Gatekeeper prompts, no extra steps.

First launch: macOS may ask for Accessibility permission -- only needed for the **Option Space** global shortcut. You can skip it if you do not need the hotkey.

---

## Build from source

```bash
git clone https://github.com/katipally/Doom-Coder.git
cd Doom-Coder
open DoomCoder.xcworkspace
```

Requires Xcode 26, macOS 26, Swift 6. Sparkle is pulled via SPM.

---

## Privacy

DoomCoder collects no analytics, sends no data to any server, and has no telemetry. See [docs/privacy.md](docs/privacy.md) for the full policy.

---

## License

MIT. See [LICENSE](LICENSE).

