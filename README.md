<div align="center">

# ⚡ Doom Coder

**Keep your Mac alive while AI agents do the work.**

[![Release](https://img.shields.io/github/v/release/katipally/Doom-Coder?style=flat-square)](https://github.com/katipally/Doom-Coder/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square)](#)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?style=flat-square)](#)

</div>

---

## What is Doom Coder?

**Doom Coder** is a tiny macOS menu bar utility that prevents your Mac from sleeping — no settings changes, no fuss.

The name is a mashup of two modern developer habits:
- **Doom scrolling** — mindlessly scrolling your phone while waiting for something
- **Vibe coding** — letting AI agents (Cursor, Claude Code CLI, GitHub Copilot) write the code while you watch

When you kick off a long AI task and walk away, macOS decides it's a great time to sleep. The AI agent then freezes, your terminal session dies, and you come back to a failed task. **Doom Coder fixes this.**

---

## How it works

When enabled, Doom Coder holds an `IOPMAssertion` with type `PreventUserIdleDisplaySleep` — a kernel-level flag that tells macOS "a user process needs the display and system awake." This is the exact same mechanism used by apps like Amphetamine and Lungo.

- ✅ **Zero CPU overhead** — it's one flag in the kernel, no polling, no timers
- ✅ **Zero memory overhead** — the app uses < 10 MB
- ✅ **Auto-released** — if Doom Coder crashes, the kernel automatically releases the assertion
- ✅ **No system settings modified** — everything is reverted the moment you disable it or quit

---

## Features

- **Menu bar only** — no Dock icon, no clutter (uses `LSUIElement = YES`)
- **One-click toggle** — `⚡` when active, `⚡/` when inactive
- **Elapsed time** — shows "Active for 2h 34m" so you know how long it's been running
- **Auto-updates** — powered by [Sparkle](https://sparkle-project.org/), updates delivered silently in the background
- **Launch at login** — start automatically on system boot (requires app in `/Applications`)
- **About window** — version info, description
- **Open source** — MIT license, build it yourself

---

## ⚠️ Important: This App is Unsigned

Doom Coder is **free and open source** and is distributed **without an Apple Developer certificate** (which costs $99/year). macOS will show a Gatekeeper warning the first time you open it.

### How to open it (do this once, then it works forever)

> **The Right-Click Method** — works 100% of the time

1. Download and unzip `DoomCoder-x.x.x.zip`
2. Drag `DoomCoder.app` to your `/Applications` folder
3. **Right-click** (or Control-click) `DoomCoder.app` in Finder
4. Select **Open** from the context menu
5. Click **Open** in the security warning dialog

That's it. macOS saves an exception for this app — you'll never see the warning again, even after updates.

> **Why does this work?**
> macOS Gatekeeper blocks apps that haven't been *notarized* by Apple (a process requiring a paid developer account). The right-click method bypasses this for apps you explicitly choose to trust. The app's source code is fully visible in this repository — you're welcome to build it yourself if you prefer.

---

## Installation

### Option 1: Download (Recommended)

1. Go to [Releases](https://github.com/katipally/Doom-Coder/releases/latest)
2. Download `DoomCoder-x.x.x.zip`
3. Unzip and move `DoomCoder.app` to `/Applications`
4. Right-click → Open (see the [unsigned warning section](#️-important-this-app-is-unsigned) above)
5. The `⚡` icon appears in your menu bar — you're ready

### Option 2: Build from Source

Requirements: Xcode 15+ (or Xcode 26 for macOS 26 SDK)

```bash
git clone https://github.com/katipally/Doom-Coder.git
cd DoomCoder
open DoomCoder.xcodeproj
```

In Xcode:
1. Select the `DoomCoder` target
2. Go to **Signing & Capabilities** → set your Apple ID team
3. Press **⌘R** to run

---

## Usage

| Menu item | Description |
|---|---|
| **Enable Doom Coder** | Activates sleep prevention. Icon changes to `⚡` |
| **Disable Doom Coder** | Releases the assertion. Normal sleep resumes |
| **Active for Xh Xm** | How long Doom Coder has been running (shown when active) |
| **Check for Updates...** | Manually trigger a Sparkle update check |
| **About Doom Coder...** | Version info and description |
| **Quit Doom Coder** | Disables assertion and exits cleanly |

---

## Verifying it works (technical)

After enabling, run this in Terminal:

```bash
pmset -g assertions | grep DoomCoder
```

You should see output like:
```
pid 23409(DoomCoder): [0x000393ed00059a31] 00:11:36 PreventUserIdleDisplaySleep
named: "DoomCoder: Preventing sleep for AI coding session"
```

You can also check the summary:
```bash
pmset -g assertions | head -10
```

Look for `PreventUserIdleDisplaySleep    1` in the system-wide assertion status.

---

## Auto-Updates (Sparkle)

Doom Coder uses [Sparkle 2](https://sparkle-project.org/) for automatic updates.

- Updates are checked automatically in the background at launch
- You can also click **Check for Updates...** in the menu anytime
- Updates are cryptographically signed with EdDSA — only releases from this repo can be delivered
- The appcast feed lives at: [`appcast.xml`](https://raw.githubusercontent.com/katipally/Doom-Coder/main/appcast.xml)

---

## For Contributors / Release Process

### Setting up GitHub Actions

Releases are fully automated. Every time you push a version tag, GitHub Actions:
1. Builds the app (unsigned)
2. Creates a `.zip` archive
3. Signs it with Sparkle EdDSA
4. Updates `appcast.xml` in the main branch
5. Creates a GitHub Release with download instructions

**One-time setup:**

1. **Get your Sparkle private key** — the key was generated when setting up this project. To retrieve it:
   ```bash
   /path/to/Sparkle/bin/generate_keys -x /tmp/my_private_key.pem
   cat /tmp/my_private_key.pem
   ```
2. **Add it to GitHub Secrets:**
   - Go to your repo → **Settings** → **Secrets and variables** → **Actions**
   - Create a secret named `SPARKLE_PRIVATE_KEY`
   - Paste the private key (a single base64 string)

3. **Tag a release:**
   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```
   The workflow triggers automatically.

### Project structure

```
DoomCoder/
├── DoomCoderApp.swift          # @main App entry, MenuBarExtra + About Window
├── SleepManager.swift          # IOPMAssertion management, elapsed time tracking
├── MenuBarView.swift           # Menu UI: toggle, status, updates, about, quit
├── CheckForUpdatesViewModel.swift  # Sparkle updater wrapper
└── AboutView.swift             # Small about window
```

---

## Privacy

Doom Coder:
- ✅ Makes **zero** network requests (except Sparkle update checks to GitHub)
- ✅ Collects **no** user data
- ✅ Has **no** analytics, telemetry, or crash reporting
- ✅ Requests **no** permissions beyond what's needed for `IOPMAssertion`

---

## License

MIT License — see [LICENSE](LICENSE) for details.

Built with ❤️ for every developer who's been burned by macOS sleeping mid-agent.

---

<div align="center">
<sub>Doom Coder — because doom scrolling + vibe coding deserves better infrastructure.</sub>
</div>
