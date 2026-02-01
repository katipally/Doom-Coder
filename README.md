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

A tiny macOS menu bar utility that prevents your Mac from sleeping while you're away. That's it — just a sleep blocker with two modes.

When you kick off a long task (big build, download, render) and walk away, macOS decides it's a great time to sleep and the job dies. **Doom Coder fixes this.**

---

## Two modes

- **Screen On** — display stays awake, Mac stays awake. Good when you want to glance at progress.
- **Screen Off** — display sleeps after a short delay, Mac stays awake. Saves power and burn-in.

Toggle from the menu bar, or globally with **⌥ Space**.

---

## How it works

Doom Coder holds an `IOPMAssertion` — the same kernel-level flag used by Amphetamine, Lungo, and `caffeinate`. That's the whole app.

- ✅ **Zero CPU / < 10 MB RAM** — one flag in the kernel, no polling
- ✅ **Auto-released** on crash, quit, or disable
- ✅ **No system settings modified** — nothing to clean up
- ✅ **Session timer** — auto-disable after 1 / 2 / 4 / 8 hours
- ✅ **Launch at login** (optional)
- ✅ **Sparkle auto-updates**

---

## Install

Download the latest `.dmg` from [Releases](https://github.com/katipally/Doom-Coder/releases/latest), drag to `/Applications`, launch.

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
