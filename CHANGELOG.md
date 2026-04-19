# Changelog

All notable changes to Doom Coder will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.8.5] - Unreleased

**Agent tracking via native hooks.** DoomCoder now tracks AI-agent sessions
(Claude Code, Cursor, VS Code Copilot, Copilot CLI) through each agent's
built-in hook system. A single bundled helper (`dc-hook`) pipes lifecycle
events through a per-user Unix socket into the app, which drives the sleep
blocker automatically and fires notifications when your attention is needed.

### Added
- `Configure Agents…` wizard: per-agent detect → preview → install →
  two-gate verify → notification channels. Never touches existing hooks —
  every entry is tagged with a `x-doomcoder: v1` sentinel and backed up.
- `Track Agents…` live popover showing running sessions and waiting states.
- Notifications: macOS local + ntfy (topic `dc-<12hex>` stored in keychain).
  File paths never leave the machine over ntfy.
- Auto-fuse: sleep blocker engages while any tracked session is active and
  releases on completion. Manual override honored (15-min cool-down).
- Right-click / menu "Pause Tracking" global kill switch (touch-file).
- SQLite event store with 7-day auto-purge under Application Support.
- One-time What's New sheet after update.

### Changed
- `MARKETING_VERSION` → 1.8.5, `CURRENT_PROJECT_VERSION` → 185.

---

## [1.8.4] - Unreleased

**Strip-down release.** Everything except the core "keep Mac awake"
functionality has been removed. Doom Coder is now a single-purpose
menu bar utility with two modes and a session timer. That's it.

### Removed
- All agent tracking (Cursor, Claude Code, Copilot CLI, etc.)
- All MCP runtime, installer, and round-trip test harness
- All hook-based watchers and rules installer
- iPhone Relay channel (ntfy / Pushover delivery)
- In-Mac notification channel
- Socket server and event bus
- Onboarding, Doctor, Agent Tracking, Configure windows
- All `Ref/` hook reference docs and most `guide/` documents
- Legacy defaults migrator
- `NSAppleEventsUsageDescription` and `NSUserNotificationsUsageDescription`
  from `Info.plist` (no longer needed)

### Kept
- Screen On / Screen Off modes (IOPMAssertion based)
- Session timer (1 / 2 / 4 / 8 hours auto-disable)
- ⌥ Space global toggle (requires Accessibility)
- Launch at Login
- Settings, Check for Updates (Sparkle), About, Quit
- Screen-off re-arm interval after user activity

---

## [1.8.3] - 2026-04-17

**Trust patch, part 2.** v1.8.2 softened the `dc` snippet from v4 to v5 but
Cursor was still firing `d` 3×/reply and spraying `w` across every planning
step. v1.8.3 adds real, server-side enforcement so the signal is reliable
even when an agent ignores the tone of the rules file.

### `dc` spam — two-layer defence
- **Snippet v6** (auto-reinstalled on launch): shorter, kinder text that
  makes "one `d` per reply" the *only* rule and marks `w` optional. Drops
  all "REQUIRED / EXACTLY ONCE" language that agents were treating as a
  formal protocol to trigger on every tool iteration.
- **Agent-level debounce in DoomCoder**: second `dc(d)` within 30 s is
  dropped; second `dc(w)` within 15 s is dropped; `dc(w)` is *also*
  dropped when the user has touched keyboard/mouse in the last 30 s
  (if you're at the Mac, the "needs input" ping is noise). Drops are
  logged under the `gate` subsystem for debugging.
- **MCP tool schema** pruned to `enum: ["w", "d"]` — `s` and `e` are
  accepted silently for back-compat but no longer advertised.

### Scope reduction
- First-class agents are now just **Cursor, Claude Code, Copilot CLI**.
  Windsurf / Gemini / Codex / VS Code MCP dropped from guided setup.
  The **Install Anywhere** pane in Agent Tracking is the generic pane
  for every other client (paste snippets for Windsurf, Zed, Claude
  Desktop, VS Code 1.95+ MCP, or any custom config).

### In-Mac alert channel (finally works)
- Previously silently dropped because `UNUserNotificationCenter`
  categories were registered lazily — if your first delivery went
  through the In-Mac channel the categories didn't exist yet.
  `NotificationManager.setup()` is now called eagerly at app launch.

### Configure sidebar
- Green ✓ checkmark on any agent that has ever completed Setup
  (independent of whether Tracking is on or whether the agent is
  currently live). Matches the "configured or not?" mental model
  users kept asking for.

### Under the hood
- `MCPRuntime.version` 8 → 9 (script auto-redeploys).
- `RulesInstaller.snippetVersion` 5 → 6.

---



**Trust + polish patch.** Fixes the three biggest sources of confusion after
v1.8.1 real-world use: the stale ⚠ badge, the paralysing 120 s "waiting for
handshake" window, and the misleading "zero tokens" claim. Adds a native
in-Mac alert channel for users who don't want to deal with ntfy.sh, rewrites
the rules snippet to stop Cursor from spamming `dc` 3×/turn, and redesigns
the menu bar Track submenu + Doctor.

### Install flow
- **Install-and-Verify no longer waits 120 s for agent activity.** Now:
  writes files → self-tests (≤5 s) → shows a clear "Restart your agent"
  handshake card with **no timeout**. All agent-dependent checks moved to
  Doctor where they belong.
- Agent is marked configured (🟢 Live the moment it says hello) right after
  self-test passes — no more stuck "installed but ⚠" rows.
- Clear per-agent restart instructions shown inline (quit + reopen vs.
  `copilot --version` in a new terminal vs. refresh MCP list).

### Rules snippet v5 + back-compat
- Rewrote the lifecycle contract: call `dc(d)` **exactly once** per real
  reply (at the very end), and `dc(w)` **once** right before asking the
  user a question. Dropped `s`/`e` letters entirely.
- Legacy `s`/`e` events from stale snippets are silently absorbed (no
  duplicate notifications).
- Bumped `snippetVersion` 4 → 5 — existing users auto-prompted to reinstall.
- Full `README.md`, `guide/agent-setup.md`, and in-app onboarding copy
  updated.

### Tracking banner + badge
- After setup, if tracking is OFF for the freshly configured agent an amber
  "Turn on tracking for [Agent]" banner appears in the Configure window
  until the user acts.
- Sidebar install badge now **observes** `mcpHelloAt` and flips 🟢 the
  instant a hello arrives — no more stale ⚠ after a successful handshake.
- `.configWritten` state returns neutral (·) instead of ⚠ when the sticky
  configured flag is set.

### New: In-Mac channel
- Brand-new attention channel: critical-priority banner + looping system
  sound (5 / 7 / 10 s, stops on click). No phone, no network, no account.
- Bypasses Focus via `.timeSensitive` interruption level (no entitlement
  required; `.critical` still available for those with one).
- Honours system mute — `NSSound` routes through master volume.

### Menu bar + window chrome
- Track submenu rebuilt with native SwiftUI `Toggle` rows (macOS 14+),
  replacing the single-select ✓-prefix list.
- Removed the `moon.zzz.fill` 💤 toolbar chip from Configure Agents;
  replaced with a neutral "Idle" / "N live sessions" pill.
- "About Doom Coder…" → "About…". Removed the placeholder icon before
  "Configure Agents" that some users read as a warning symbol.
- Row action button renamed from `eye`/`eye.fill` to `bell`/`bell.fill`
  (matches notification semantics).

### Doctor
- Each MCP-agent probe row now includes the timestamp of the **last `dc`
  call** ("last dc 12 m") so you can instantly see whether the agent is
  actively talking to DoomCoder.
- Per-agent **Self-test** button inline on each row — runs the mcp.py
  round-trip and shows pass/fail + duration without waiting on the real
  agent.

### Honesty
- Replaced every "zero tokens" claim with "about 50 tokens per `dc` call".
  MCP tool schemas + call + result are real bytes; we're transparent about
  it now.


---

## [1.8.1] - 2026-04-17

**v1.8.0 polish — Setup flow, stale-session UX, Doctor dashboard, onboarding explainer.**
Follow-up patch to the v1.8.0 overhaul. Fixes the duplicated "waiting for handshake"
step users reported, replaces the mysterious 30-minute "timed out" banner with a
gentler every-2h informational ping, surfaces a live Doctor dashboard, and adds a
welcome page explaining how DoomCoder actually works.

### Setup sheet
- **Collapsed 3 steps → 2.** Explain → Install-and-Verify. The old separate Verify
  step duplicated the 30-second handshake wait that Install was already doing;
  it's now a single streaming log.
- Added an inline "Waiting for [Agent] — restart it, then start any chat" strip
  so users know what DoomCoder is actually waiting for.
- Added a Mac ↔ Socket ↔ Agent diagram and a "What's happening?" disclosure with
  plain-English explanation of MCP + rules snippet handshake.
- Cursor gets a prominent **Copy snippet** action with toast feedback and a direct
  "Open Cursor → Settings → Rules" button right in the Install step.
- Verify timeouts rebalanced: 30 s self-test + 60 s handshake + 60 s first tool
  call (was 30 / 30 / 30 — too tight for Cursor cold starts).

### Stale-session rework
- Idle threshold raised 30 min → 2 hours, and the session is **no longer
  auto-closed**. A big task that genuinely runs for 6 hours stays tracked.
- Instead of a single "timed out" banner, DoomCoder now sends an informational
  "[Agent] — session inactive 2h+" banner every 2 hours with an interactive
  **End session** action. Click the action to stop watching without opening the
  app.

### Live Tracking + Doctor
- Live Tracking window audit: every configured agent renders with a clear
  per-agent toggle. Unconfigured agents show a disabled row with an "Open
  Configure" CTA so the tab isn't a dead-end.
- Doctor now **auto-runs on open** — parallel MCP self-test and per-agent
  handshake check, with live green / amber / red status pills and a per-row
  "Fix" link that opens the Setup sheet for that agent.

### Onboarding
- Added a **"How DoomCoder works"** welcome page (page 1) with the
  Mac ↔ Socket ↔ Agent diagram and a 20-second explainer so first-run users
  understand why they're pasting rules and what MCP is before they're asked
  to configure anything.

---

## [1.8.0] - 2026-04-20

**Full UX overhaul — naming, tracking, Cursor, and transport cleanup.**
DoomCoder v1.8 is the polish release: every window, menu, and setup flow
has been renamed for clarity; Tracking is now per-agent toggles instead
of a single radio selection; Cursor has a dedicated paste-to-User-Rules
workflow so it fires globally instead of only on direct mention; and the
legacy hook transport has been deleted entirely — every agent now uses
MCP.

### Renamed

- **"Full" mode → "Screen On"** (display stays on, Mac awake). "Screen Off"
  mode keeps its name (display sleeps, Mac stays awake). Persisted
  mode value `"full"` auto-migrates to `"screenOn"`.
- **"DoomCoder Doctor" window → "Doctor"**.
- **"Agents & Channels" window → "Configure Agents"**.
- Menu item copy polished throughout the menubar popover.

### Tracking refactor

- `WatchTarget` (`.none` / `.all` / `.agentType`) is gone. Tracking is
  now a `Set<String>` of watched agent IDs — one toggle per configured
  agent in the menubar's Track submenu and in the Configure sidebar.
- Gate still requires BOTH watched AND configured, so toggling an
  unconfigured agent is a no-op.
- Saved `dc.watchTarget` auto-migrates to `dc.watchedAgentIds` on first
  launch (`.all` → every configured agent, `.agentType(x)` → `{x}`,
  `.none` → empty).

### Cursor

- Setup sheet now surfaces a prominent **"Cursor requires one extra
  paste"** callout with a **Copy snippet** button and an **Open Cursor**
  button that opens Cursor → Settings (via `cursor://settings`).
- Rationale: `~/.cursor/rules/doomcoder.mdc` only auto-attaches for
  projects rooted at your home folder. For every-project coverage the
  snippet has to live in Cursor's User Rules, which Cursor does not
  expose as a writable file as of April 2026.

### Removed (transport cleanup)

- Deleted `HookInstaller.swift`, `HookRuntime.swift`, `HookRoundTripTest.swift`.
- Removed every UI branch that tested `info.tier == .hook`. The `tier`
  field is gone; every agent is MCP.
- `AgentEvent.Source.hook` enum case is retained for wire-format
  back-compat (old hook scripts still emit `src:"hook"`), but default
  decode is now `.mcp`, and no new hook installations are created.
- `dc.didRoundTrip` UserDefaults dict is cleared on migration.
- **Upgrade note:** if you previously ran a hook install, the shell
  config line will still be on disk. Re-run Setup for each agent in the
  Configure window to switch cleanly to MCP. The old line is inert
  without the hook runtime script, which v1.8 no longer deploys.

### Assets + docs

- `logo.png` and `logo-doomcoder.png` moved to `assets/`. README
  references updated; `.gitignore` simplified.

---



**"End is mandatory" rule hardening.**
Rules snippet v4 + MCP tool description v8 reframe the protocol as
"your turn is not complete until you call `dc(status='d')`" — including
trivial chat replies, refusals, and error paths. Agents in 2026 had
been skipping the final `d` on short-form replies where they didn't
invoke any other tool; this pass makes the terminal `d` explicitly
required on EVERY turn with no opt-out.

### Changes
- `RulesInstaller.snippetVersion` 3 → 4. New wording: "Your turn is NOT
  complete until you have called `dc(status='d')`. This applies to EVERY
  user turn without exception — simple chat replies, refusals, and
  errors included." Existing v3 blocks auto-replace via the sentinel.
- `MCPRuntime.version` 7 → 8 forces `mcp.py` redeploy. Tool description
  mirrors the rules wording so agents that ignore global rules still see
  the "REQUIRED for every turn" text in the tool schema itself.
- `s` downgraded to optional-for-trivial-turns; `d` stays mandatory.

## [1.7.0] - 2026-04-17

**Single-letter protocol + always-on auto-invoke.**
The MCP pipeline has been green end-to-end since v1.6, but two UX papercuts
remained: agents were sending verbose custom `message` strings to the
server, and most agents only called `dc` when the user explicitly said
"use doomcoder mcp". v1.7 closes both gaps by locking the protocol to a
single letter and planting rules in the documented *global* instruction
files for every supported host.

### Changed
- **Canonical notification bodies.** DoomCoder no longer forwards the
  agent's `message` field into ntfy or the mac banner. The body is now
  derived deterministically from the status letter:
  - `s` → *"Agent started working"* (silent — attention=false)
  - `w` → *"Needs your input"*
  - `e` → *"Hit an error"*
  - `d` → *"Task complete"*
  Every delivery reads the same regardless of which model or prompt
  produced it.
- **MCP tool schema lock-down.** `dc` now accepts a single parameter:
  `status` (enum `s|w|e|d`). `message`, `tool`, `cwd`, `sessionKey`, and
  `repo` have been removed from `inputSchema`. Agents that still send a
  `message` field because of cached older rules get it silently dropped
  and a `[mcp-fwd] ignored-message-len=N` line written to stderr so you
  can monitor compliance in Console.app. `MCPRuntime.version` bumped
  `6 → 7` so every existing install rewrites `~/.doomcoder/mcp.py` on
  next launch.
- **Rules snippet v3 (imperative).** `snippetVersion 2 → 3`. The wording
  is now explicitly *non-optional, system-level* and tells the agent to
  "Never require the user to ask for it" — fixing the v1.6 regression
  where most models would only invoke the protocol after an explicit
  prompt. Old `v2` blocks are rewritten in place on next install (the
  sentinel regex already matched any version).
- **Copilot CLI: dual global rules paths.** DoomCoder now writes the
  snippet to both `~/.copilot/AGENTS.md` (the file DoomCoder used in
  v1.4–1.6; kept for backward compat) *and* `~/.copilot/copilot-instructions.md`
  (Copilot CLI's documented global instructions file). No migration, no
  deletion — both files get the sentinel block, uninstall strips both,
  status reports installed if the v3 block is present in either.
- **Cursor setup note.** Cursor's per-user rules live in Settings → Rules
  → User Rules and are not writable from outside the app as of April
  2026. The setup console now surfaces a copy-paste blurb telling the
  user to paste the snippet there once for every-project auto-invoke.

### Internals
- `AgentEvent.Status.canonicalBody` — single source of truth for
  body copy. `IPhoneRelay.fire` and `NotificationManager.fire` both
  call it; `sendTest` keeps its hand-rolled body.
- `RulesInstaller.Agent.rulesPaths: [URL]` replaces the old scalar
  `rulesPath: URL` (kept as a computed back-compat alias returning the
  primary path). `install` / `uninstall` / `status` / `backupIfPresent`
  all iterate. Per-path backup filenames include the basename to avoid
  collision in a shared `backupDir`.

---

## [1.5.0] - 2026-04-17

**Configure vs. Track — clean separation of setup and live selection.**
The old "Agent Tracking" window was doing too much (install, live status,
channels, tests) and the "Watch this agent" submenu listed every random
running IDE/CLI DoomCoder couldn't actually talk to. v1.5 splits them:
the window is **setup only**, and the menubar submenu shows **only
agents the user has verified** end-to-end.

### Changed
- **Window renamed: "Agent Tracking" → "Agents & Channels".** New scene
  id `configure`. Title, toolbar, and all open-window call sites updated.
- **Menubar submenu renamed: "Watch this agent" → "Track".** Entries
  are drawn strictly from agents the user has configured — a hook agent
  qualifies after a successful round-trip, an MCP agent after a hello
  handshake. Both facts are now persisted across launches.
- **Track is agent-type-level, not per-instance.** Selecting "Copilot
  CLI" watches every Copilot CLI session. Per-session ids were removed
  — they were unstable between launches and confused the UX.
- Sidebar section labels cleaned up: "iPhone Channels" → "Channels",
  "System" → "Diagnostics".
- Per-agent **Track** button added to each Ready row in the Configure
  window — one-click alternative to the menubar submenu. Disabled and
  dimmed when the agent isn't configured yet.

### Added
- `WatchTarget` enum (`.none` / `.all` / `.agentType(id)`) replacing
  the legacy `watchedSessionKey: String`. "Track none (silent)" is now
  an explicit menu row for muting all notifications without disabling
  DoomCoder.
- `AgentStatusManager.isAgentConfigured(_:)` and `configuredAgents()`
  helpers, feeding the Track submenu and the new Track buttons from
  one source of truth.
- Persisted `didRoundTrip[agentId]` — set on any successful
  `HookRoundTripTest`. Agents stay "Configured" after a restart.
- Persisted `mcpHelloAt[agentId]` — promoted from in-memory to
  UserDefaults so MCP agents survive the same restart gate.

### Removed
- **Live Sessions sidebar section** in the Configure window. Live
  status belongs in the menubar Track submenu; the window is for setup.
- `RunningAgentScanner` and its associated menubar "Rescan" button.
  The scanner's guesswork (processes that *might* be agents but had no
  verified wiring) was the root cause of users seeing ghost entries in
  the submenu. Gone entirely — the Track list is now exact.
- `AgentTrackingSelection.liveSession` case and the `SessionDetailPane`
  call site (pane file kept for reference, no longer reachable).

### Migration
One-shot on first launch: legacy `dc.watchedSessionKey` is read and
discarded — empty or non-empty alike both become `WatchTarget.all`
(old session ids weren't safe to carry forward). No user action needed.

---

## [1.4.1] - 2026-04-17

### Fixed
- **Crash on `com.doomcoder.socketserver.accept` (serial queue).**
  The accept-loop event handler captured the `@MainActor`-isolated
  `SocketServer` and passed it across the actor boundary to a static
  helper, which traps under Swift 6 strict concurrency — causing
  reproducible crashes during the round-trip hook test, during MCP
  handshake from Cursor, and any time a hook or MCP client connected
  for the first time. Rewrote the socket layer: all I/O now lives in
  a nonisolated `SocketCore` helper that only captures `Sendable`
  state (fd + a `@Sendable` forwarder closure). The forwarder hops to
  `MainActor` exclusively for final delivery to `onEvent`. No behaviour
  changes, same socket path, same event framing.

---

## [1.4.0] - 2026-04-17

Hook/MCP reliability + menubar **Watch this agent** flow. Fixes an install-
time crash, rewrites Copilot CLI hooks to the April 2026 native `hooks.json`
format, adds per-tab identity so two tabs never collide, ships real
round-trip hook tests, and introduces a diagnostics panel.

### Added
- **Watch this agent** menubar submenu — lists every running Copilot CLI /
  Claude Code / Cursor / Windsurf / Codex / VS Code / Zed process with
  per-instance details (folder, tty, elapsed) and one-click pinning. Only
  pinned sessions appear in the sidebar and fire notifications.
- **Install Anywhere** pane — marketplace-style page with a copy-pastable
  DoomCoder MCP snippet, per-client instructions (Cursor, Windsurf, Codex,
  Claude Desktop, VS Code, Zed, Custom), and a Verify button that waits up
  to 2 min for any MCP client to hand-shake.
- **Real round-trip hook test** — spawns `~/.doomcoder/hook.sh`, times how
  long the event takes to reach our socket, reports `✓ 12 ms` or a
  diagnostic (`socket not listening`, `script missing`, `silent`). Replaces
  the animated 4.5 s staged test.
- **DoomCoder Doctor** (menubar → *DoomCoder Doctor…*) — one-click probes
  for every agent's hook script / MCP sentinel / live hello TTL plus system
  checks (socket listening, python3, Accessibility, notifications, ntfy,
  `~/.doomcoder`, macOS version). Includes a **Copy report** button.

### Changed
- **Copilot CLI hooks** rewritten to the April 2026 native format —
  `~/.copilot/hooks/hooks.json` covering `sessionStart`, `sessionEnd`,
  `preToolUse`, `postToolUse`, `userPromptSubmitted`, `errorOccurred`. The
  legacy `extensions/doomcoder/hook.sh` install path is removed.
- **Session identity** now walks the process tree to the real `copilot`
  pid and always captures `tty`, so two Copilot CLI tabs that share a
  login shell ancestry never collide. Rows now show `agent · folder ·
  tty`.
- **MCP hello** now forwards `clientInfo.name` from the `initialize`
  request so Install Anywhere can show *which* client loaded the config
  (e.g. Cursor vs Windsurf).

### Fixed
- **Install-time crash on `com.doomcoder.socketserver.accept`.** Audited
  every force-unwrap in `SocketServer.swift` and the event decoder;
  partial writes, oversized lines, non-UTF8 bytes, and unknown JSON
  schemas are all logged and dropped instead of crashing.
- **Cursor project-shadow configs.** When installing, DoomCoder now warns
  about any `.cursor/mcp.json` in recent-workspaces that would silently
  shadow the global install.
- **Codex TOML CRLF** handling — replaced regex-based merge with a
  line-based parser; writes LF only.
- **`aider` agent** removed from the catalog — there was no installer
  path behind it.



Reliability pass: honest hook statuses, a real MCP handshake so "installed"
means the agent actually loaded the config, and per-tab session identity so
two Cursor chats don't collapse into one row.

### Fixed
- **Hook event mapping (v3).** `UserPromptSubmit` / `PreToolUse` / `PostToolUse`
  now correctly map to `info` (progress), not `wait`. `Stop` / `SubagentStop`
  map to `wait` (end of turn, expecting next prompt), not `done`. Only
  `SessionEnd` closes a session. Bumps `DC_HOOK_VERSION=3` so every install
  auto-refreshes the shim on next launch.
- **Hook payload now includes `message`.** Claude Code's `Notification` event
  carries the permission-request text ("Bash: `rm -rf node_modules`"); we
  forward it to ntfy so the push shows *why* the agent is waiting.
- **Session key falls back to a cwd hash** when neither `session_id` nor
  `pid` is available. Two Copilot CLI tabs or two Cursor chats in different
  projects no longer collapse into one row.
- **`injectTest` is now a staged sequence.** Verify/test events fire
  `start → wait → done` over ~4.5s instead of a permanent `wait` zombie in
  the sidebar.
- **TOML writer escapes backslashes** in addition to quotes.

### Added
- **MCP live handshake.** The server script now takes `--agent` /
  `--install-id` args and emits a synthetic `mcp-hello` on its `initialize`
  RPC. `MCPInstaller.Status` grows a 5-state enum (`notInstalled /
  configWritten / live / modified / missingConfig`); only `.live` turns the
  sidebar chip green. Setup sheet polls for 10 s after install and prompts
  the user to restart the agent if no handshake arrives.
- **Per-agent install-id.** Every install generates a fresh UUID that
  correlates "the install we wrote" with "the process that came alive."
  Hello timestamps are persisted per (agent, install-id) so relaunches don't
  lose the live state.
- **Dedup triple key.** Collapse key is now
  `(sessionId, status, tool)`, so back-to-back permission prompts for
  different tools aren't silently merged.

### Changed
- Stale-session timeout raised from 10 → 30 minutes. Real Claude sessions
  routinely idle longer between prompts.
- `actions/checkout@v4` → `@v5` across CI (silences the Node 20 deprecation
  warning).
- MCP wire format uses AgentEvent abbreviated keys (`src`/`s`/`t`) so MCP
  events can no longer be silently decoded as hook events.

### Removed
- **Aider** from AgentCatalog. No installer backed the row — it was a
  dead-end placeholder.



Calendar channel removed; ntfy is now the sole built-in delivery method.
Delivery is now **single-channel with an explicit active-method picker** so
adding more channels in the future is a drop-in.

### Removed
- **Calendar/iCloud alarm channel.** The approach was structurally unreliable:
  even with the 1.1.1 fixes, iCloud CalDAV propagation to the phone's alarm
  evaluator never had a guaranteed upper bound, and `macOS 26` was silently
  rejecting `URL`-bearing alarms on non-entitled processes
  (`Attempted to set URL on an alarm in a process that is not allowed.
  Ignoring.`). Rather than ship more heuristics on top of a leaky primitive,
  the channel is gone. EventKit is no longer linked; `NSCalendars…UsageDescription`
  keys removed from `Info.plist`.
- **Per-channel enabled toggles.** Replaced by one active-method selection —
  a channel becomes "enabled" implicitly by being selected.

### Added
- **Active-method dropdown** at the top of **Agent Tracking → System → Delivery
  Log**. Shows every configured-and-ready channel plus a **"None — silence
  iPhone alerts"** option for paused sessions. Each channel's detail pane
  also has a **Set as Active** button and a callout when it's currently the
  active method. Future channels (SMS, Pushover, …) register once in the
  `IPhoneRelay.allChannels` array and appear automatically.
- **Sidebar "Active" badge** on the iPhone channel currently selected for
  delivery so the status is visible at a glance.

### Changed
- `IPhoneRelay.fire()` now dispatches to exactly one channel (the active
  selection) instead of fanning out. `sendTest(channel:)` replaced with
  `sendTest(channelID:)`.
- `LegacyDefaults.migrateV12()` clears `dc.iphone.calendar.enabled` and
  `dc.iphone.ntfy.enabled`, and if either was true with an ntfy topic set
  it pre-selects `ntfy` so existing setups keep working with zero clicks.

---

## [1.1.1] - 2026-04-17

Patch for the Calendar + ntfy onboarding shipped in 1.1.0.

### Fixed
- **Calendar alarms now fire on iPhone reliably.** 1.1.0 scheduled the alarm
  3 seconds in the future — too tight for iCloud CalDAV push to propagate to
  the phone before the local alarm evaluator fired there. Bumped to **15 s**
  (well inside real-world iCloud latency tails) and added a second fallback
  alarm at `-5 s` for redundancy. Delivery log now surfaces whether the event
  landed on iCloud or a Local source so you can tell at a glance if iCloud
  Calendars sync is off.
- **ntfy topic is short and typeable** — `dc-xxxxxxxx` (11 chars, ~32 bits of
  entropy) instead of `doom-` + 22 base32 chars. Easy to paste or even type on
  a phone if the share sheet fails.
- **ntfy setup UI simplified** — replaced the "Share Deep Link / Copy Deep
  Link / Copy Web URL" trio with two plain **Topic** and **Server** copy
  rows showing exactly what to enter in the ntfy iOS app's Subscribe dialog.
  Share sheet + QR are still there as an opt-in disclosure for one-tap
  flows.

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

[1.8.4]: https://github.com/katipally/Doom-Coder/compare/v1.8.3...v1.8.4
[0.2.1]: https://github.com/katipally/Doom-Coder/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/katipally/Doom-Coder/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/katipally/Doom-Coder/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/katipally/Doom-Coder/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/katipally/Doom-Coder/releases/tag/v0.1.0
