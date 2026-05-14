<div align="center">

<img src="assets/logo.png" alt="Doom Coder" width="400" />

# ⚡ Doom Coder

**Keep your Mac awake while AI agents work — and watch them live.**

[![Release](https://img.shields.io/github/v/release/katipally/Doom-Coder?style=flat-square)](https://github.com/katipally/Doom-Coder/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue?style=flat-square)](#)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?style=flat-square)](#)

</div>

---

## What is Doom Coder?

A macOS menu bar utility that does two things:

1. **Keeps your Mac awake** while a long task runs (build, render, download, or an AI coding agent working through a multi-step task).
2. **Tracks your AI coding agents live.** Hook into Claude Code, Cursor, VS Code, GitHub Copilot CLI, Windsurf, and Codex — and see every event flow through the menu bar as it happens.

When you kick off a long task and walk away, macOS decides it's a great time to sleep and the job dies. **Doom Coder fixes that** — and tells you the moment the agent needs you back.

---

## Sleep modes

- **Screen On** — display stays awake, Mac stays awake. Good when you want to glance at progress.
- **Screen Off** — display sleeps after a short delay, Mac stays awake. Saves power and burn-in.

Toggle from the menu bar, or globally with **⌥ Space**.

---

## Agent tracking

Doom Coder installs lightweight hook configs into each agent you opt in to — no daemon, no polling, no system extensions. When an agent fires a hook (tool call, prompt submit, session start, notification, etc.), it's piped through a tiny helper binary into the menu bar in real time.

Each of the 6 supported agents has its own tracker with:
- Its own native event taxonomy (Claude's 25 events, Cursor's 20, VS Code's 8, Copilot CLI's 6, Windsurf's 12, Codex's 6 — no cross-agent normalization, no dropped fields).
- Its own running-state probe (NSWorkspace for `.app` agents, process scan for CLIs).
- Per-agent per-event notification toggles.

Hook configs are installed into each agent's native location (`~/.claude/settings.json`, `~/.cursor/hooks.json`, `.github/hooks/doomcoder.json`, etc.) and can be cleanly uninstalled.

---

## How it works (sleep blocker)

Doom Coder holds an `IOPMAssertion` — the same kernel-level flag used by Amphetamine, Lungo, and `caffeinate`.

- ✅ **Zero CPU / < 10 MB RAM** — one flag in the kernel, no polling
- ✅ **Auto-released** on crash, quit, or disable
- ✅ **No system settings modified** — nothing to clean up
- ✅ **Session timer** — auto-disable after 1 / 2 / 4 / 8 hours
- ✅ **Launch at login** (optional)
- ✅ **Sparkle auto-updates**

---

## Install

Download the latest `.dmg` or `.zip` from [Releases](https://github.com/katipally/Doom-Coder/releases/latest):

- **DMG**: open it and drag DoomCoder into your Applications folder
- **ZIP**: unzip, drag `DoomCoder.app` to `/Applications`, double-click to open

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
