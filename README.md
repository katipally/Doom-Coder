<div align="center">

<img src="assets/logo.png" alt="Doom Coder" width="400" />

# ⚡ Doom Coder

**Track your AI coding agents from your Mac — and your phone.**

[![Release](https://img.shields.io/github/v/release/katipally/Doom-Coder?style=flat-square)](https://github.com/katipally/Doom-Coder/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue?style=flat-square)](#)
[![iOS 26+](https://img.shields.io/badge/iOS-26%2B-blue?style=flat-square)](#)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?style=flat-square)](#)

</div>

---

## What is Doom Coder?

Doom Coder is a **free, open-source** monitoring system for AI coding agents (Claude Code, Cursor, Copilot CLI, Codex, Windsurf). It consists of two apps that work together:

| | **macOS App** | **iOS App** |
|---|---|---|
| **What it does** | Menu bar agent monitor — tracks every tool call, decision, and session from your AI agents | Live Activities, Dynamic Island, and rich notifications on your phone |
| **Distribution** | [GitHub Releases](https://github.com/katipally/Doom-Coder/releases/latest) (signed + notarized) | App Store |
| **Pairing** | — | Sign into the same iCloud — no setup needed |
| **Backend** | CloudKit private DB (Apple-hosted, zero server) | Same |

The Mac app captures everything your agents do via a **hook script** injected into each agent's config. Events flow to the iOS app instantly via CloudKit silent pushes — no account sign-up, no external services, no subscription.

---

## macOS App

### What you see

- **Menu bar icon** — animates while any agent session is active
- **Live sessions panel** — tool calls, model, token usage, elapsed time, per-agent status
- **Approval requests** — when Claude Code pauses and asks for permission, approve or deny from your Mac (or phone)
- **History** — past sessions with full event log
- **Settings sync** — preferences sync to your iPhone automatically

### Install

1. Download the latest `DoomCoder-*.zip` from [Releases](https://github.com/katipally/Doom-Coder/releases/latest)
2. Unzip and drag `DoomCoder.app` to `/Applications`
3. Double-click to open — the app is **signed and notarized by Apple**, so it opens without any Gatekeeper warning

### Set up agent hooks

Open DoomCoder → **Configure Agents** → follow the one-click install for each agent you use. The installer writes a hook config pointing to the bundled `dc-hook` binary that captures rich telemetry (tool name + args, model, token usage, exit codes, session boundaries).

**Supported agents:** Claude Code · Cursor · Copilot CLI · Codex CLI · Windsurf · VS Code Copilot

---

## iOS App

### What you get

- **Live Activities + Dynamic Island** — see active agent sessions at a glance without unlocking your phone
- **Rich notifications** — approval requests, errors, session end summaries (with agent, model, tool counts)
- **Approval actions** — Approve / Deny / Always Allow directly from the notification or Lock Screen
- **Live tab** — all active sessions with animated status, tool counts, elapsed timer
- **History tab** — paginated session history with 7-day retention
- **Settings sync** — mirrors your macOS notification preferences

### Pairing

Just sign into the same iCloud account on both devices. No QR codes, no tokens, no API keys — CloudKit handles the rest.

---

## Architecture

```
  Claude Code · Cursor · Copilot CLI · Codex · Windsurf
          │
          ▼  (hook script — dc-hook binary)
  ┌─────────────────────────────────┐
  │   macOS App  (DoomCoder.app)    │
  │                                 │
  │  HookSocketListener             │
  │  AgentTrackingManager           │
  │  CloudKitPublisher  ──────────► CloudKit private DB (iCloud)
  │  ApprovalCoordinator            │          │
  │  SleepManager                   │          │ silent APNs push
  └─────────────────────────────────┘          │
                                               ▼
                                     ┌─────────────────────┐
                                     │  iOS App             │
                                     │                      │
                                     │  ActivityKit (LA)    │
                                     │  NotificationHandler │
                                     │  ApprovalResponder   │
                                     └─────────────────────┘
```

- **No server.** CloudKit private DB is Apple-hosted infrastructure — events never touch a third-party service.
- **No account.** Pairing = same iCloud account, automatic.
- **No subscription.** Both apps are free and MIT licensed.
- **Sleep prevention.** The Mac app also holds an `IOPMAssertion` during active sessions so your Mac never sleeps mid-run.

---

## Build from source

```bash
git clone https://github.com/katipally/Doom-Coder.git
cd Doom-Coder
open DoomCoder.xcodeproj
```

**Requirements:** Xcode 26 · macOS 26 · Swift 6 · iOS 26 Simulator (for iOS target)

Sparkle is pulled via SPM automatically.

```bash
# macOS build
xcodebuild -project DoomCoder.xcodeproj -scheme DoomCoder \
  -configuration Debug -destination 'platform=macOS' build

# iOS build (Simulator)
xcodebuild -project DoomCoder.xcodeproj -scheme DoomCoderiOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

---

## Hook documentation

See [`Ref/`](Ref/) for per-agent hook configuration reference:
- [`Ref/Claude-code-hooks.md`](Ref/Claude-code-hooks.md)
- [`Ref/cursor-hooks.md`](Ref/cursor-hooks.md)
- [`Ref/Codex-hooks.md`](Ref/Codex-hooks.md)
- [`Ref/Copilot-cli-hooks.md`](Ref/Copilot-cli-hooks.md)
- [`Ref/VScode-agent-hooks.md`](Ref/VScode-agent-hooks.md)

---

## Privacy

- **No analytics** — zero telemetry, no crash reporting, nothing phoned home
- **No account** — sign-in is your existing iCloud
- **Your data only** — CloudKit private DB is accessible only to you; Apple cannot read it
- **Open source** — audit everything in this repo

Full privacy policy: [katipally.github.io/Doom-Coder/privacy](https://katipally.github.io/Doom-Coder/privacy)

---

## License

MIT. See [LICENSE](LICENSE).

