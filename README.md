<div align="center">

<img src="assets/logo.png" alt="Doom Coder" width="400" />

# ⚡ Doom Coder

**Keep your Mac awake. Nothing else.**

[![Release](https://img.shields.io/github/v/release/katipally/Doom-Coder?style=flat-square)](https://github.com/katipally/Doom-Coder/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue?style=flat-square)](#)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?style=flat-square)](#)

</div>

---

## What is Doom Coder?

A macOS menu bar app that does two things:

1. **Keeps your Mac awake** while long-running jobs (builds, downloads, agents) finish — without changing system settings.
2. **Tracks coding agents** (Claude Code, Cursor, VS Code, Copilot CLI, Windsurf, Codex CLI) and notifies you the moment they finish, fail, or need your attention — on your Mac and on your iPhone via the free **DoomCoder Companion** iOS app.

No accounts, no servers, no telemetry. Notifications travel through your own private iCloud container.

---

## Two modes

- **Screen On** — display stays awake, Mac stays awake. Good when you want to glance at progress.
- **Screen Off** — display sleeps after a short delay, Mac stays awake. Saves power and burn-in.

Toggle from the menu bar, or globally with **⌥ Space**.

---

## How it works

**Sleep blocker.** Doom Coder holds an `IOPMAssertion` — the same kernel-level flag used by Amphetamine, Lungo, and `caffeinate`.

- ✅ **Zero CPU / < 10 MB RAM** — one flag in the kernel, no polling
- ✅ **Auto-released** on crash, quit, or disable
- ✅ **No system settings modified** — nothing to clean up
- ✅ **Session timer** — auto-disable after 1 / 2 / 4 / 8 hours
- ✅ **Launch at login** (optional)
- ✅ **Sparkle auto-updates**

**Agent tracker.** Doom Coder installs lightweight hooks into each agent's config so it knows when sessions start, finish, fail, or stall. Notifications are rendered locally on the Mac and mirrored to your iPhone through your private CloudKit database — no third-party server.

## iPhone companion

`DoomCoder Companion` (iOS 26+) mirrors every Mac notification to your iPhone in 1–5 seconds. It shows the same agent list, per-agent status, and a 7-day notification log. Install from the App Store and sign into the same iCloud account as your Mac — that's the entire setup.

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
