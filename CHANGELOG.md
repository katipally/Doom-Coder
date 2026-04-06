# Changelog

All notable changes to Doom Coder will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.7.0] - 2026-04-06

### Fixed
- **CLI agents stuck in "working" state** — Two independent false-positive sources eliminated:
  - *Network false positive:* `WorkingStateDetector` now uses **receive-buffer delta only** (bytes received since last 2s poll must exceed 500 bytes). Previously it fired if the buffer had any data > 100 bytes, which idle keep-alive TCP connections satisfy permanently.
  - *Child process false positive:* `TrackedApp.isWorking` for CLI tools now requires **≥ 2 direct child processes** instead of > 0. Most CLI agents (Copilot CLI, Claude Code) keep exactly 1 persistent helper subprocess alive at the idle prompt; requiring 2+ avoids this false trigger while still detecting real task execution.
- **Network activity window** tightened from 4 s → 3 s (matching 1.5 poll cycles) to clear stale "working" state faster.

### Added
- **"Task started" notification** — When a tracked AI tool transitions from idle → working (after being idle for at least 6 s), a notification fires: **"[App] is working…"**. Pairs with the existing "finished" notification to bracket each task session.
- **Per-agent notifications** — each agent sends its own start/done notification independently. No batching or summary messages.

---

## [0.6.0] - 2026-04-06

### Added
- **Dynamic AI app discovery** — no hardcoded app list. Scans all `$PATH` directories, Homebrew, Cargo, npm global, bun, volta, nvm, Python user bins, `~/.local/bin`, `~/.claude/bin`, `/Applications`, `~/Applications`, and user-defined custom paths. Matches found executables and bundles against AI tool name patterns.
- **FSEvents file watching** — attaches a zero-overhead `FSEventStream` to IDE workspace storage directories for Cursor, VS Code, Windsurf, and Zed. Detects real-time AI generation activity (rapid SQLite writes) with a 1.5 s coalescing window.
- **Network bytes monitoring** — uses `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` to read per-socket receive buffer sizes for tracked CLI agent PIDs every 2 s. A spike in `sbi_cc` delta (> 500 bytes) marks the agent as "working". No root/sudo required.
- **Aggregated "isWorking" signal** — `isWorking = childProcessCount > 0 || FSEvents burst within 3 s || network bytes delta`. This combines all three independent signals so no working session is missed.
- **Idle completion notifications** — fires a macOS notification when a tracked app transitions from working → idle (minimum 15 s working session required to debounce false positives). Title: "Task Complete", body names the app.
- **Settings → Tools tab** — new tab in the Settings window to add/remove custom CLI binary names and custom GUI bundle identifiers. Changes persist via `UserDefaults` and immediately trigger an app re-scan.
- **Signal column in Active Apps window** — shows which signals detected the working state: `procs` (child processes), `net` (network bytes), `fs` (FSEvents).

### Changed
- Active Apps window expanded to 460 × 340 to accommodate the Signal column.
- Settings window converted to a `TabView` (General + Tools tabs), height 480 px.
- `DoomCoderApp` passes `appDetector` to `SettingsView` so the Tools tab can trigger rescans.
- `Info.plist` adds `NSUserNotificationsUsageDescription` for notification permission.

---

## [0.5.0] - 2026-04-05


### Added
- **GitHub Copilot CLI agent detection** — `copilot` binary is now tracked and displayed as "GitHub Copilot CLI" in the Active Apps window. Detects the agent started via `copilot` in any terminal.
- **"Working" state for CLI agents** — CLI tools (Claude Code, Copilot, Codex, Aider, etc.) now show **"working (N tasks)"** in the Status column when they have active child processes (shell commands, git, compilers, file writes, etc.). This is the definitive signal that an agent is executing work — not just sitting at a prompt.
- **"Working" state for GUI apps** — editor apps (Cursor, VS Code, Windsurf) show **"active"** when CPU is meaningfully elevated above idle (>2%).
- **Dot color indicator** — green dot = working/active; yellow dot = running but idle; gray dot = not running.

### Changed
- Status column now shows: `working (N tasks)` → `running` → `idle` → `not running` instead of just active/idle.
- Status text is green when working, secondary when idle, tertiary when not running.
- Internal: replaced `currentUserProcesses() → [String: pid_t]` with `getAllUserProcesses() → [ProcInfo]` that also captures `ppid` in one sysctl pass — used to build a child-count map with zero extra syscalls.

---



### Added
- **Active Apps window** — dedicated window (App | Status | CPU%) replacing the old inline menu list. Opens via "Active Apps…" menu item; includes a Scan button and thermal status footer.
- **Settings window** — clean Form-based window with Launch at Login toggle and Accessibility permission status/grant button for the global hotkey.
- **⌥ Space global hotkey** — replaces the old Fn+F1 shortcut. Toggles Doom Coder on/off from anywhere. Requires Accessibility permission; a "Grant Access" button in Settings opens System Preferences and polls for permission automatically (no relaunch needed).
- **Smooth screen-off fade** — Screen Off mode now uses `CGDisplayFade` for a 0.8-second cinematic fade to black before sleeping the display (no jarring instant-off).
- **Dynamic PATH detection** — `AppDetector` now reads `/etc/paths` and `/etc/paths.d/` to discover system-defined binary paths at runtime (Homebrew, npm, etc.) instead of relying on a hardcoded list.
- **Gemini CLI detection** — added `gemini` to tracked CLI tools.

### Changed
- **Removed Auto-Dim mode entirely** — two clean modes remain: Full (always on, screen stays on) and Screen Off (Mac stays awake, display fades off). No gamma manipulation, no idle-timeout complexity.
- **Menu redesign** — no emojis, no inline app list, no thermal in menu. Clean structure: toggle → status → Mode → Session Timer → Active Apps… → Settings… → Updates/About/Quit.
- **Process scanning efficiency** — `AppDetector` now uses `KERN_PROC_UID` (current user only) instead of `KERN_PROC_ALL`, reducing sysctl overhead.

### Fixed
- Hotkey would fail silently if Accessibility permission was granted after app launch — permission polling now detects the grant within 2 seconds without requiring a relaunch.
- Removed incorrect `NSUserNotificationUsageDescription` Info.plist key.

---

## [0.3.1] - 2026-04-05

### Fixed
- **Critical crash at launch** — `UNUserNotificationCenter.requestAuthorization()` was called twice at startup via the completion-handler API from a `@MainActor` class. On macOS Sequoia with ad-hoc signed apps, the framework returns an error and calls its internal cleanup code from a background thread, triggering a libdispatch main-thread assertion (`BUG IN CLIENT OF LIBDISPATCH`) that crashed the app before the menu bar icon could appear. Fixed by switching to the async/await API (`try await requestAuthorization()`) wrapped in a `Task {}`, which handles actor switching correctly, and by removing the duplicate call during init.
- **App blocked main thread at startup** — `AppDetector.init()` performed synchronous file-system scans (`/Applications` plist reads) and `sysctl(KERN_PROC_ALL)` on the main thread, delaying app launch. All init work is now deferred to a `Task` that runs after the app finishes launching.
- **Menu checkmarks not rendering correctly** — SwiftUI `HStack { Text; Spacer; Image(systemName: "checkmark") }` inside `Button` labels does not reliably render in macOS native NSMenu style (the default for `MenuBarExtra`). Replaced with a `checkLabel(_:_:)` helper that prepends `"✓ "` to the string directly — this works correctly in all rendering modes.
- **"Launch at Login" toggle not reflecting state immediately** — `isLaunchAtLoginEnabled` was a computed property that bypassed `@Observable` tracking. Converted to a stored `private(set) var` updated explicitly in `toggleLaunchAtLogin()`, so the checkmark updates instantly after clicking.

## [0.3.0] - 2026-04-05

### Added
- **Screen-Off Mode** — New third mode that turns the display completely off (`pmset displaysleepnow`) while keeping the Mac and all running processes fully alive using `kIOPMAssertionTypePreventSystemSleep`. Perfect for long AI tasks where you don't need to see the screen but don't want the machine to sleep.
  - 5-second countdown in the menu before the screen turns off
  - Display wakes automatically on any mouse/keyboard input (standard macOS behavior)
  - **Re-arm**: after N minutes of user idle, the screen turns off again automatically (configurable: 5/10/15/30 min, default 10)
- **AI App Detection** — Automatically detects installed and running AI coding tools on your Mac.
  - Scans for GUI apps: Cursor, VS Code, VS Code Insiders, Windsurf, Zed, Xcode, iTerm2, Warp, Ghostty, Terminal, Alacritty, and JetBrains IDEs
  - Scans for CLI tools in common install paths: `claude`, `codex`, `aider`, `windsurf`, `continue`, `goose`, `amp`, `copilot`, and more
  - Only shows apps actually installed on your device
  - Updates running state every 10 seconds
- **Live CPU% for Running Apps** — Each running tracked app shows its current CPU usage, sampled asynchronously using `ps` (zero overhead).
- **Task Completion Notifications** — When a tracked AI tool's CPU drops below 2% for ~2 minutes, Doom Coder sends a system notification: "🤖 [App] has gone idle — your task may be complete." Counter resets if CPU rises again.
- **Launch at Login** — Toggle in the menu to enable/disable launching Doom Coder at login (uses `SMAppService`, no helper process).
- **Global Hotkey Fn+F1** — Toggle Doom Coder on/off from anywhere without clicking the menu bar icon. Requires Accessibility permission (prompted when first used). A "Grant Accessibility Access" button appears in the menu if permission is not yet granted.
- **Settings Persistence** — Screen-Off re-arm timeout is now persisted across restarts.

### Changed
- Mode picker now shows three options: Full Mode, Auto-Dim Mode, Screen-Off Mode
- Menu reorganized with cleaner sections: Status, Mode, Mode Settings, Session Timer, Thermal, Detected Apps, Options

## [0.2.1] - 2026-04-04

### Fixed
- **Auto-Dim was completely non-functional on Apple Silicon Macs** — The previous implementation used `IODisplayGetFloatParameter` / `IODisplaySetFloatParameter` (IOKit display API), which returns zero services on Apple Silicon. Replaced with `CGGetDisplayTransferByFormula` / `CGSetDisplayTransferByFormula` (CoreGraphics gamma table API), which works on all Macs. Screen now visibly dims to the selected level after the idle timeout and instantly restores on any mouse or keyboard activity.
- **Timers didn't fire reliably** — Changed all internal timers (`Timer.scheduledTimer`) to use `RunLoop.main.add(t, forMode: .common)` so they fire in `.common` mode instead of `.default`, ensuring consistent behavior.
- **Auto-Dim Settings submenu headers were broken** — `Text()` inside a SwiftUI `Menu` renders as a disabled menu item, not a section header. Replaced with proper `Section("Idle Timeout")` and `Section("Dim Level")` for correct macOS menu appearance.
- **Idle detection missed mouse clicks and scrolling** — Added `leftMouseDown`, `rightMouseDown`, and `scrollWheel` event types to the idle check, preventing false-positive dimming when clicking without moving the mouse.
- **Mode picker was confusing** — Replaced bullet-character radio buttons with a clear `Mode` submenu with descriptions for each option.
- **Added gamma safety net** — `CGDisplayRestoreColorSyncSettings()` is now called on app exit/crash via `deinit`, ensuring the display gamma is always restored even if the app exits unexpectedly while screen is dimmed.

## [0.2.0] - 2026-04-04

### Added
- **Auto-Dim Mode** — new mode that automatically dims the screen after configurable idle time (2, 5, or 10 minutes) and instantly restores brightness on mouse/keyboard activity. Protects against display burn-in during long unattended sessions.
- **Configurable dim level** — choose minimum brightness: 5%, 10%, or 20% when auto-dim activates.
- **Thermal monitoring** — real-time system thermal state displayed in the menu (🟢 Normal / 🟡 Fair / 🟠 Serious / 🔴 Critical). Zero overhead — notification-driven via `ProcessInfo.thermalState`.
- **Session timer** — optional auto-disable after 1, 2, 4, or 8 hours with countdown display in the menu. Prevents accidentally leaving the Mac awake overnight.
- **Custom app icon** — Doom Coder now has its own logo (skeleton vibe-coding with headphones).
- **Mode picker in menu** — switch between Full Mode (screen always on at full brightness) and Auto-Dim Mode.
- **Settings persist** across app restarts via UserDefaults (mode, idle timeout, dim level, session timer).

### Changed
- About window now shows the app icon and updated feature description.
- Menu structure redesigned with mode picker, settings submenus, and thermal/timer displays.

## [0.1.2] - 2026-04-04

### Fixed
- **App failed to launch (dyld crash)** — Added `com.apple.security.cs.disable-library-validation` entitlement. Hardened runtime's Library Validation requires all loaded code to share the same Team ID, which is impossible with ad-hoc signing. This entitlement allows the embedded Sparkle framework to load correctly.
- **Proper bottom-up code signing** — Replaced deprecated `codesign --deep` with individual component signing in the correct order: XPC services → Sparkle helpers → Sparkle framework → main app (with entitlements). Each binary includes `--options runtime` for hardened runtime.
- **Accurate Gatekeeper instructions** — Updated README and release notes with correct macOS Sequoia (15+) / macOS 26 instructions. Right-click bypass no longer works; users must use System Settings → Privacy & Security → Open Anyway.
- **Synced local project version** — Info.plist now matches the release version (0.1.2).

## [0.1.1] - 2026-04-04

### Fixed
- **"App is damaged" error on macOS 14+** — CI now properly ad-hoc signs the app bundle and all nested Sparkle components (XPCServices, Autoupdate helper, Updater.app) using `codesign --force --deep --sign -`. Previously the build had `CODE_SIGNING_ALLOWED=NO` which produced a completely unsigned binary that macOS 14+ rejects as "damaged".
- Updated installation instructions in README to include the `xattr -cr` Terminal method (works on all macOS versions) alongside the right-click method.

## [0.1.0] - 2026-04-04

### Added
- Initial release 🎉
- Menu bar icon (`⚡` when active, `⚡/` when inactive) — no Dock icon, lives purely in the menu bar
- Toggle to enable/disable sleep prevention with a single click
- Elapsed time display ("Active for 2h 34m") when Doom Coder is running
- Prevents both **display sleep** and **system sleep** using `IOPMAssertionTypePreventUserIdleDisplaySleep` — zero CPU overhead, kernel-level flag
- Sparkle auto-update support — "Check for Updates..." in the menu
- About window with version info
- Launch at login support (requires app to be in `/Applications`)
- Targets macOS 14+ (Sonoma and later)

[0.2.1]: https://github.com/katipally/Doom-Coder/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/katipally/Doom-Coder/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/katipally/Doom-Coder/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/katipally/Doom-Coder/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/katipally/Doom-Coder/releases/tag/v0.1.0
