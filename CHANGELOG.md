# Changelog

All notable changes to Doom Coder will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.1.0] - 2026-04-16

Major reliability release — replaces broken iPhone delivery channels with a
mechanism Apple actually supports end-to-end, removes two features that
couldn't be made reliable, and rebuilds the ntfy onboarding UX so it works
without needing QR-to-Safari workarounds.

### Added
- **Calendar channel (primary iPhone delivery).** DoomCoder now creates a short
  `EKEvent` with a 3-second `EKAlarm` on a dedicated **DoomCoder** calendar
  stored in iCloud. The alarm fires locally on every device signed into the
  same iCloud account — iPhone, iPad, Apple Watch — within seconds, regardless
  of Focus mode, and without ever landing in Recently Deleted. Old DoomCoder
  events auto-clean after 15 minutes so the calendar stays empty.
- **Real iCloud round-trip test for Calendar.** The Verify step and the
  SYSTEM → iCloud pane both run a deterministic round-trip: write a probe
  event with no alarm, poll a fresh `EKEventStore` every 500ms, delete on
  match, report the latency. Propagation timeouts surface an actionable error.
- **ntfy subscribe flow rebuilt from scratch.** The Install step now offers
  three paths: **Share…** (native share sheet pushes the `ntfy://subscribe?topic=…`
  deep link straight to your iPhone via AirDrop/Messages), **Copy Deep Link**,
  and **Copy Web URL**. The QR is still there as a fallback but is now
  collapsed and explicitly labeled ("camera will open Safari — that's fine").

### Removed
- **Reminders channel.** On macOS 26 iCloud-synced reminders with due-date
  alarms are marked completed before the alarm fires, landing them in
  Recently Deleted without a notification. No workaround was reliable.
  Existing users migrate to Calendar automatically (if Reminders was enabled,
  Calendar gets enabled).
- **iMessage channel.** Apple permanently blocks iMessage-to-self delivery
  when the same Apple ID is signed in on both ends — the delivery framework
  returns "Not Delivered" silently. Cannot be worked around; removed.
- **Focus Filter integration.** Too many users never mapped a Focus to the
  filter and the feature added surface area without reliable benefit. Dropped
  to keep v1.1 tight.
- `NSRemindersUsageDescription`, `NSFocusStatusUsageDescription`,
  `NSContactsUsageDescription` removed from Info.plist.

### Migration
- `doomcoder.iphone.reminder.enabled` → `doomcoder.iphone.calendar.enabled`
  (carries your opt-in forward).
- `doomcoder.iphone.imessage.enabled` forced to `false`.
- `doomcoder.focus.*` wiped.
- Runs once on first 1.1 launch, logged as `LegacyDefaults v1.1: migrated N keys`.

### Changed
- Agent Tracking SYSTEM section is now **iCloud Round-Trip** + **Delivery Log**
  only (Focus Filter row removed).
- Info.plist now requests `NSCalendarsFullAccessUsageDescription` /
  `NSCalendarsUsageDescription`.
- Version bumped to **1.1.0 / 110**.



Hotfix for iPhone delivery channels shipped in 1.0.0.

### Fixed
- **Reminders now actually push to iPhone.** 1.0.0 wrote completed reminders
  which iCloud synced silently into the Completed section — no notification
  ever fired. 1.0.1 writes an **uncompleted** reminder with a due-date alarm
  set to `now`, which is what the Reminders app consumes to trigger an
  iPhone notification. A sentinel tag (`[dc-reminder/v1]`) in the note field
  lets DoomCoder auto-complete its own reminders older than an hour so the
  list stays tidy. Cleanup runs opportunistically on app launch and before
  each delivery.
- **iMessage delivery is far more resilient.** Handles are now normalized to
  E.164 (whitespace/parens/dashes stripped, leading `+` enforced for numeric
  handles, emails preserved). Delivery tries the canonical `buddy` form
  first, falls back to the more permissive `participant` form on buddy-lookup
  failure. AppleScript errors are decoded to actionable messages: `-1743`
  → "Automation permission denied", `-1728` → "Handle not registered with
  iMessage", `-600` → "Messages.app not running".
- **Permission priming inline in Agent Tracking.** The iPhone-channel detail
  pane now has a "Request Permission" (Reminders) and "Prime Automation"
  (iMessage) button that triggers the TCC prompt on demand instead of
  requiring users to send a test notification first.
- **Test notifications from a session now deliver.** SessionDetailPane's
  Test button used `.info` status which the relay's `isAttention` guard
  silently dropped. Now uses `.wait` so the test actually fires.
- **Sparkle gentle-reminders warning silenced.** DoomCoder now advertises
  `supportsGentleScheduledUpdateReminders = true` via its Sparkle user
  driver delegate — required for menu-bar background apps to surface
  scheduled update alerts correctly.
- **Idle toolbar indicator refreshed.** The Agent Tracking toolbar shows a
  pulsing bolt + "N live sessions" when active, or a dimmed moon + "Idle"
  when waiting, centered in a translucent capsule instead of the cramped
  leading position.
- Silenced benign `AccentColor not present` warning by removing the stale
  asset-catalog reference.

### Technical notes
- `EKReminder` isn't `Sendable` under Swift 6 strict checking. Cleanup code
  extracts the reminders' `calendarItemIdentifier` strings inside the
  EventKit callback before crossing actor boundaries, then re-fetches each
  reminder by id on the main store to mutate it.
- TCC permissions may invalidate on ad-hoc debug rebuilds because each build
  gets a fresh ad-hoc code signature. Release builds signed with the
  Developer ID certificate don't have this problem. No code fix is
  possible; this is a macOS security-model constraint.

---



**The Agent Tracking release.** v1.0 is a full rewrite of the primary UX
around the Agent Bridge. Every line of heuristic detection code is gone,
Settings is now a thin shell, and all onboarding + live session tracking
lives inside a first-class **Agent Tracking** window with guided per-agent
setup sheets, macOS 26 Focus Filter automation, and a true iCloud
round-trip test for Reminders delivery.

### Added
- **Agent Tracking window** — Primary surface of the app. Three-pane
  `NavigationSplitView` with Live Sessions (sorted by most-recent activity),
  Agents (all 7 supported tools with install-status badges), iPhone
  Channels (Reminders / iMessage / ntfy with setup + test), and System
  (Focus Filter, iCloud sync, Delivery Log). Opens from the menu-bar
  status header or `Open Agent Tracking…`. Uses macOS 26 refinements and
  `.glassEffect` styling.
- **Guided Setup Sheets** — 3-step onboarding (explain → install →
  verify) for every agent and every iPhone channel. iMessage auto-fills
  the handle from the Contacts Me-card. ntfy generates a random topic
  and renders a QR code for iPhone subscription. Reminders step 3 runs
  the full iCloud round-trip test.
- **iCloud Round-Trip Test** — `ReminderChannel.runICloudRoundTripTest()`
  writes a unique marker reminder, polls a fresh `EKEventStore` for
  propagation, confirms, then cleans up — returning observed latency.
  The only way to deterministically verify iPhone delivery will work.
- **DoomCoder Focus Filter** — New `SetFocusFilterIntent` that DoomCoder
  donates on every `AgentStatusManager.anyWorking` flip. Map it to any
  Focus mode in System Settings → Focus → [mode] → Focus Filters, and
  your iPhone will silence other apps while a coding agent is actively
  working.
- **Per-session live detail pane** — Last 25 tool calls ring buffer,
  wait reasons, current tool, elapsed time. Every "Send Test
  Notification" button fires the real IPhoneRelay pipeline (no mocks).
- **Delivery log export** — Advanced tab exports the last 50 deliveries
  as JSON for debugging.
- **Launch at Login ON by default** for new installs.
- **New CI workflow** (`ci.yml`) — Runs `xcodebuild build` with
  `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` on every PR. Blocks merges that
  reintroduce warnings.

### Changed
- **macOS minimum bumped to 26.0 (Tahoe).** Every `@available(macOS 15,
  *)` guard removed.
- **Version 1.0.0 / build 100.**
- **Menu bar** pivots to a status header that opens Agent Tracking.
  The `Agents` submenu (which opened Settings) and the `Active Apps…`
  item are gone.
- **Settings** slimmed to 2 tabs: **General** (Launch at Login,
  accessibility) and **Advanced** (bridge status + restart, runtime
  versions, redeploy, delivery log export). The Tools, Agent Bridge,
  and iPhone tabs are removed — all that functionality now lives in
  Agent Tracking.
- **Release CI** runs on `macos-26` (Xcode 26). Dropped the
  `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` workaround.
- **Sparkle appcast** `minimumSystemVersion` bumped to `26.0`.
- **Hook runtime v2 / MCP runtime v2** — upgrading installs auto-refresh
  both on first launch.

### Removed
- **Heuristic detection stack.** `WorkingStateDetector.swift`,
  `AppDetector.swift`, `ActiveAppsView.swift`, and
  `DynamicAppDiscovery.swift` are deleted. If an agent isn't hooked or
  MCP-connected, DoomCoder doesn't track it — and the Agent Tracking
  window tells the user exactly how to fix that with one click.
- **Legacy UserDefaults keys** — `customCLIBinaries`, `customGUIBundles`,
  `detectedApps.*`. `LegacyDefaults.migrate()` runs once on first v1.0
  launch to wipe them silently.
- **`AgentBridgeSettingsView.swift`** and **`IPhoneSetupView.swift`** —
  replaced by Agent Tracking detail panes and setup sheets.

### Migration
First v1.0 launch runs `LegacyDefaults.migrate()` once (silent, no
modal), redeploys the hook + MCP runtimes at v2, and preserves all
existing agent hook configs. No user action required.

---

## [0.8.0] - 2026-04-16

**The Agent Bridge release.** Replaces the v0.6 heuristic-only tracking with a deterministic three-tier architecture (shell hooks + MCP server + silent heuristic fallback), adds triple-redundant iPhone notifications, per-agent Settings cards, a live-session dashboard, and an in-app Help menu.

### Added — Status dashboard + Help menu + Tier-3 demotion (Phase D/E)
- **Live session dashboard** in Settings → Agent Bridge — real-time list of every active agent session with state dot, repo, current tool, tool call count and elapsed time. Sourced directly from `AgentStatusManager.sessions` via `@Observable`.
- **Menu bar live-session indicator** — when any agent session is active, the menu-bar bolt icon gains a monospaced session count next to it, and a dedicated "Agents: N live" submenu lists each session with a one-click jump into Settings.
- **Help submenu** — menu-bar → Help → Agent Setup Guide / iPhone Notifications Guide / Hooks Reference / Troubleshooting — each opens the corresponding page on GitHub. Plus a one-click "Report an Issue" link.
- **Tier-3 heuristic demotion** — `NotificationManager.shouldSuppressHeuristic` closure is now wired to `AgentStatusManager.isAnyAgentActive`. Whenever the bridge has a live session, the legacy CPU/FSEvents/network heuristic path stays silent. Eliminates double-firing for agents connected via hooks or MCP while preserving the heuristic as a true fallback for unsupported tools.
- **`guide/` pages** — `agent-setup.md`, `iphone-notifications.md`, `hooks-reference.md`, `troubleshooting.md`. Comprehensive setup walkthroughs, full hook/MCP protocol reference, and a diagnostic cookbook for every failure mode.
- **README rewrite** — Agent Bridge and iPhone Notifications sections added at the top of the Features list, with direct links to every guide page.
- **`appcast.xml`** — 0.7.0 entry placeholder added; release asset + ed signature filled in by `scripts/release.sh`.

### Added — iPhone Relay (Phase C)
- **Triple-redundant iPhone notifications** — every attention-grabbing event (wait for input / error / done) now fans out in parallel to three independent channels, so a slow iCloud sync or denied permission never costs you the alert:
  - **iCloud Reminders** — drops a completed reminder into your default Reminders list; Apple's own sync pushes it to your iPhone in seconds. Zero network calls from DoomCoder itself.
  - **iMessage to yourself** — sends an iMessage via Messages.app to a handle you configure. Fastest of the three. Uses AppleScript; no API keys, no accounts.
  - **ntfy.sh** — opt-in push via ntfy's free public server. DoomCoder generates an unguessable topic (`doom-<22 hex>`); install the ntfy iOS app, subscribe to the URL, done.
- **Settings → iPhone tab** — per-channel cards with toggles, Grant Access buttons, live Ready/Off/Needs-permission status dots, and a Send Test button per channel.
- **Delivery log** — every attempt (success or failure, with latency detail) is recorded in-app so you can confirm the path works end-to-end.
- **`NSRemindersUsageDescription`** and **`NSAppleEventsUsageDescription`** added to Info.plist for the first-run permission prompts.

### Added — Agent Bridge MCP (Phase B)
- **`~/.doomcoder/mcp.py` runner** — self-deployed Python 3 MCP server bundled into DoomCoder (stamped with `DC_MCP_VERSION` so updates auto-refresh). Exposes a single `dc` tool with a one-character `s` param (`s/w/i/e/d` for start/wait/info/error/done), keeping per-session token cost to roughly 140 tokens.
- **Five-agent installer** — Cursor, Windsurf, VS Code, Gemini CLI, Codex. JSON-merge for the first four (writes `~/.cursor/mcp.json`, `~/.codeium/windsurf/mcp_config.json`, `~/Library/Application Support/Code/User/mcp.json`, `~/.gemini/settings.json`); TOML-section editor for Codex (`~/.codex/config.toml`). All entries tagged with a `doomcoder-managed` sentinel so Uninstall cleanly removes only our section.
- **Agent Bridge tab** now shows the MCP-based agents alongside hook-based ones with matching Setup / Uninstall / Restore / Send Test controls.

### Added — Agent Bridge (Phase A)
- **Unix-socket transport** at `~/.doomcoder/dc.sock` — deterministic, per-event, zero-polling bridge for AI agent status. Replaces heuristic detection for any agent that speaks to us directly. Mode `0600`, owner-only.
- **`AgentStatusManager`** — central state machine that dedups events in a 10-second window per session, auto-finalises stale sessions after 10 minutes, and exposes a live `sessions` list to the UI.
- **Claude Code hook installer** — one-click **Agent Bridge → Set Up** writes eight managed hook commands (`SessionStart`, `SessionEnd`, `PreToolUse`, `PostToolUse`, `Notification`, `UserPromptSubmit`, `Stop`, `SubagentStop`) into `~/.claude/settings.json`, preserving every existing user entry via merge + timestamped backup. Idempotent re-install, clean Uninstall, Restore-Backup buttons.
- **Copilot CLI extension installer** — installs a tiny `~/.copilot/extensions/doomcoder/hook.sh` shim that forwards lifecycle events to the DoomCoder bridge. No impact on Copilot tokens or behavior.
- **`hook.sh` runner** — POSIX shell script auto-deployed to `~/.doomcoder/hook.sh` on every launch; reads hook JSON from stdin, emits one line of compact JSON to the socket via `nc -U` (Python 3 fallback), never blocks the agent (exits 0 on any failure).
- **Settings → Agent Bridge tab** — per-agent cards with live status badges (Connected / Partial / Not set up), plain-English setup copy, "What we changed" disclosure with Reveal-in-Finder and Restore-Backup, and a "Send Test Notification" button that injects a synthetic event through the full pipeline.
- **Rich agent notifications** — notifications driven by hook events now carry the agent name (Claude Code / Copilot CLI), repo name, and elapsed time; attention-only (wait / error / done) so no spam during normal tool use.

### Fixed
- **CLI agents stuck in "working" state** — Two independent false-positive sources eliminated:
  - *Network false positive:* `WorkingStateDetector` now uses **receive-buffer delta only** (bytes received since last 2s poll must exceed 500 bytes). Previously it fired if the buffer had any data > 100 bytes, which idle keep-alive TCP connections satisfy permanently.
  - *Child process false positive:* `TrackedApp.isWorking` for CLI tools now requires **≥ 2 direct child processes** instead of > 0. Most CLI agents (Copilot CLI, Claude Code) keep exactly 1 persistent helper subprocess alive at the idle prompt; requiring 2+ avoids this false trigger while still detecting real task execution.
- **Network activity window** tightened from 4 s → 3 s (matching 1.5 poll cycles) to clear stale "working" state faster.

### Added (earlier in 0.7.0)
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
