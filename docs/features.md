# DoomCoder — Full Feature Reference

This document covers every feature, setting, and behavior in DoomCoder. Each section maps to a place in the UI. Hover the **ⓘ** icons in the app for inline summaries.

---

## Menu bar panel

The panel opens when you click the DoomCoder icon in the menu bar, or by pressing the global hotkey (default **⌥ Space**).

### Master toggle

The large toggle at the top of the panel is the master on/off switch for the entire app.

| State | What happens |
|---|---|
| **On** | Sleep blocker runs; agent notifications are delivered. |
| **Off (Suspended)** | Sleep blocker stops and all notifications pause. The app stays in the menu bar; hook events are still recorded in the local log. |

Turning the master back on resumes exactly where it left off.

### Prevent Sleep card

#### Keep-Awake mode

| Mode | Behavior |
|---|---|
| **Off** | macOS manages sleep normally. DoomCoder holds no IOPMAssertion. |
| **On** | Always holds the sleep assertion. Choose a screen mode and optional session timer below. |
| **Auto** | Holds the assertion while any tracked agent is actively working (running, waiting for input, or waiting for approval). Releases after a 5-minute grace once all agents are idle. Respects per-agent tracking toggles — agents toggled off are excluded. |

#### Screen mode (when Keep-Awake is On)

| Mode | Behavior |
|---|---|
| **Screen On** | Display stays fully lit the whole time. Mac never sleeps. |
| **Screen Off** | Display sleeps after a short delay; Mac CPU stays awake. Saves power and reduces screen burn. When you move the mouse the display wakes; DoomCoder re-sleeps it after the re-arm interval. |

#### Duration / session timer (when Keep-Awake is On)

Tap a tile to start the sleep blocker with that time limit. Tap the stop tile to disable immediately.

| Tile | Behavior |
|---|---|
| **None** | Runs indefinitely until you stop it manually. |
| **1h / 2h / 4h / 8h** | Auto-disables the sleep blocker when the timer expires. |

### Agent Tracking card

Shows configured agents with their live status. The green count badge shows how many sessions are actively running.

- **Configure →** opens the full Configure window.
- Each agent row shows a status dot (green = running, yellow = waiting, grey = idle) and a per-agent notification toggle.

---

## Configure window

Open from the panel → Configure, or from the footer Settings button.

### Agents tab (sidebar)

Each agent has:
- **Name and detected version** (or "not found" if the app isn't installed).
- **Health dot** — green if at least one hook event was received in the last hour; grey otherwise.
- **⚠ warning badge** — appears if DoomCoder detects that the installed hook config has drifted from what it wrote (e.g. another tool edited it). Select the agent and click **Repair**.
- **✓ checkmark** — confirms hooks are installed.

### Agent detail pane

#### Detection

Shows whether the agent app/CLI is installed and its detected version. Click **Re-scan** after installing or updating an agent.

#### What you'll be notified about

Lists the notification events this agent can emit. Events are agent-specific:

| Event | Agents |
|---|---|
| Task completed | All |
| Task failed | All |
| Waiting for approval | Claude Code, Copilot CLI |
| Waiting for input | VS Code Copilot, Windsurf |
| Session started | All |
| Tool calls | Claude Code, Copilot CLI, Codex CLI |

#### Health

Live stats: active/quiet status, events today, time of last event.

#### Hook Warning

If the installed hook config has drifted (missing events, wrong binary path, or external edits), a warning appears here with a description of the diff. Click **Repair** to reinstall.

#### Prerequisites

Per-agent checklist of requirements. Each item shows whether it's met and a fix hint if not.

| Agent | Key prerequisites |
|---|---|
| Claude Code | `~/.claude/` exists and `settings.json` is writable. Run `claude` once to initialize. |
| Cursor | Cursor 0.45+ with Hooks enabled (Settings → Beta → Hooks). |
| VS Code Copilot | VS Code with Copilot Chat extension. `~/.copilot/vscode-hooks/` writable. |
| Copilot CLI | CLI installed (`npm i -g @github/copilot`). `~/.copilot/` exists. |
| Windsurf | Windsurf installed and opened once so `~/.codeium/windsurf/` is created. |
| Codex CLI | CLI installed (`npm i -g @openai/codex`). Run `codex` once to create `~/.codex/`. |

#### Hooks (install/uninstall)

| Action | Description |
|---|---|
| **Install** | Writes `dc-hook` calls into the agent's config. Backs up the existing file first. |
| **Reinstall** | Overwrites the hooks (shown when already installed). |
| **Uninstall** | Removes all `dc-hook` references from the agent's config. Verifies the result on disk. |
| **Reveal file** | Opens the config file in Finder. |
| **Open in IDE** | Opens the config file in the agent's own editor. |

**VS Code variants** — when VS Code is selected, a checkbox group lets you choose which VS Code-family `settings.json` files to patch: VS Code Stable, VS Code Insiders, VSCodium, Cursor, Windsurf.

#### Connection Doctor

Sends a synthetic test event through the full hook pipeline and waits for DoomCoder to receive it. If the round-trip succeeds, the doctor shows the event in the Live Events panel. If it times out, the doctor reports where the pipeline broke.

#### Live Events

Real-time stream of hook events received from this agent. Events auto-scroll to the bottom. Click an event to expand the JSON payload. Click **Clear** to reset the stream.

#### Channel Overrides

By default, each agent uses the global channel settings. Enable **Use custom channels** to set macOS and iPhone channels independently for just this agent — for example, send Claude Code completions to your iPhone but skip VS Code Copilot.

---

### Notification Channels tab

Global defaults applied to all agents (unless overridden per-agent).

#### Permission Status

Shows whether macOS notifications are authorized. Click **Allow Notifications** or **Open Settings** to grant/restore permission.

#### macOS notifications

Toggle on to receive banner notifications on your Mac. Click **Test** to send a test notification immediately.

#### iPhone / iPad (iCloud)

Toggle on to mirror notifications to the DoomCoder Companion iOS app via your private iCloud container.

**iCloud status indicator** — must show green ("Connected to iCloud as…") for iPhone mirroring to work. If it stays grey, check that you're signed into iCloud in System Settings and that iCloud Drive is enabled.

Click **Test** to send a test push to your iPhone.

[Get DoomCoder Companion on the App Store](https://apps.apple.com/app/doomcoder-companion/id6772514212)

#### Notify me when…

Fine-grained control over which events trigger a notification. Settings apply to all agents (unless overridden).

| Toggle | Default | What it covers |
|---|---|---|
| Session completed | ✅ On | Agent finishes its task successfully. |
| Errors | ✅ On | Tool errors, permission errors, aborted runs. |
| Permission requests | ✅ On | Agent waiting for you to approve a tool call. |
| Agent responses | Off | Each reply the agent sends (verbose). |
| Session started | Off | Beginning of a new agent session (verbose). |
| Sub-agent activity | Off | Agent spawns sub-agents or parallel tasks. |
| Tool usage | Off | Every file read/write/run tool call (very verbose). |

---

### Logs tab

Browsable history of all hook events and notifications. Retained for **7 days**.

- **Filter bar** — filter by agent or switch to the 🔔 Notifications view.
- **Expand rows** — click any event row to expand the full JSON payload with a clean rendered view and a Raw JSON toggle.
- **Export** — export the current view to JSON or CSV from the footer.
- **Retention** — configurable from the footer (default 7 days).

---

### Settings tab

#### General

| Setting | Description |
|---|---|
| **Launch at Login** | Registers DoomCoder as a login item via `SMAppService`. |
| **Open DoomCoder shortcut** | The global hotkey that opens the panel from anywhere. Default: ⌥ Space. Displayed read-only; change it in the field (coming soon: in-UI rebinding). |

#### Screen Off

| Setting | Default | Description |
|---|---|---|
| **Re-sleep display after** | 5 min | After moving the mouse wakes the display in Screen Off mode, DoomCoder re-sleeps it after this many idle minutes. Range: 1–60 minutes. |

#### Session Lifecycle

| Setting | Default | Description |
|---|---|---|
| **Auto-revert completed sessions** | 30 s | How long the "completed" or "failed" badge stays on an agent row before it reverts to "idle". Range: 10–120 seconds. |

#### Notifications & Privacy

| Setting | Default | Description |
|---|---|---|
| **Redact prompt text in local history** | On | Hides agent prompt and response content in the Logs view and event history. Event type, timing, and status are still recorded. |

#### Diagnostics

**Reveal Logs** — opens `~/Library/Logs/DoomCoder/` in Finder. Log files are named `doomcoder-YYYY-MM-DD.log` and kept for 7 days.

### AI tab (sidebar)

A dedicated sidebar section (not a sub-tab) for the engine that powers prompt **Enhance**.

| Setting | Description |
|---|---|
| **Engine** | **On-device** (Apple Intelligence, fully local) or **My API key** (BYOK provider). |
| **Provider / API key / Model** | When using your own key, pick a provider, paste the key (**Save & test key** validates it and fetches available models), and choose a model. |

On-device requires a supported Mac with Apple Intelligence enabled; otherwise the pane explains why it's unavailable. Prompts and notes are stored only on this Mac — nothing is synced. On-device stays fully local; with a provider key, prompt text is sent to the chosen provider over HTTPS only when you tap Enhance.

---

## Prompts & Notes

A lightweight toolbox window. Both panes focus the editor on open so a first-time user can start typing immediately — no guide needed.

### Prompts

- **Compose** — a full-height editor with **Enhance with AI**, **Copy**, and **Save/Update**. Enhance rewrites your draft using the configured engine; **Undo** restores the pre-Enhance text. Writing and copying never require AI.
- **Library** — a curated collection of high-quality development prompts; open one into the composer or copy it.
- Saved drafts live in the sidebar with search.

### Notes

On-device notes with title, body, tasks, reminders, and pinning — all first-class, all local to this Mac.

| Feature | Description |
|---|---|
| **Title** | An explicit title field at the top of the editor. Legacy notes fall back to their first line. |
| **Body** | Freeform note text. |
| **Tasks** | An inline checklist — add, check off, and remove to-dos right inside the note. |
| **Reminder** | A **Remind me** toggle with a date/time picker schedules a local notification (stays on this Mac). Permission is requested only when you first set one. |
| **Pin / Copy / To Prompt / Delete** | Actions in the editor's bottom bar. Pinned notes sort to the top. |

Search matches titles, body, and task text.

---

## Track Agents window

Accessible from the Agent Tracking card in the main panel.

- **Per-agent toggle** — disable notifications for a specific agent without uninstalling its hooks. Events still land in the event store.
- **Paused** — pauses all agent notifications immediately. This is an **in-memory flag** — it resets every time DoomCoder is relaunched. The sleep blocker keeps running while paused.
- **Reveal logs** — opens the log directory in Finder.

---

## Global hotkey

Default: **⌥ Space**. Works system-wide without Accessibility permission (uses Carbon `RegisterEventHotKey`, the same mechanism as Spotlight).

If the shortcut conflicts with another app, a banner appears in the panel with a **Fix** link to the Settings pane.

---

## iPhone & iPad companion

**DoomCoder Companion** (iOS 26+) is a **standalone app that is fully usable on first launch with no setup** — no Mac, no iCloud pairing, and no API key required. Connecting a Mac is an optional enhancement, not a requirement.

### Works with zero setup (no Mac, no key)
- **Prompts** — a *Compose | Library* tab. Compose lets you draft a prompt and copy it; the **Library** is a curated collection of high-quality daily-development prompts (write tests, refactor, explain an error, code review, debug, docstrings, commit messages, regex, SQL, API design, performance, security review, and more) that you can copy or open in the composer.
- **Notes** — on-device notes with pinning, inline checklists, search, **reminders** (local notifications), and "Turn into prompt".
- **Dashboard** — three stacked sections that mirror the Mac panel: a **DoomCoder** master on/off toggle, a **Keep Awake** sleep-control section (mode, screen, and session timer), and an **Agents** list. Before a Mac is paired the controls explain that a connected Mac is required; the standalone Prompts and Notes tabs always work.
- **Settings** — choose the AI engine (On-device Apple Intelligence or your own API key), manage notifications, and pair/unpair a Mac. The **Connection** section shows the paired Mac's name, last-seen time, and a live status indicator.

### Optional AI (Enhance)
Prompt **Enhance** is a graceful bonus that uses either Apple's on-device model or your own provider key (BYOK). On-device AI is unavailable in the iOS Simulator and on unsupported devices, in which case the app shows clear guidance and the rest of the app keeps working.

### Optional Mac connection (mirroring)
When you sign in to the **same iCloud account** on your Mac and iPhone and enable iPhone / iPad in Configure → Notification Channels, the companion mirrors every Mac notification in 1–5 seconds via your private iCloud container (CloudKit) — no third-party server, no API keys, no QR codes. With a Mac paired you also get the live agent list, per-agent notification history, a 7-day session log, and remote keep-awake / master on-off controls.

---

## Technical details

### dc-hook binary

A small helper binary (`dc-hook`) is installed into `~/Library/Application Support/DoomCoder/dc-hook`. It is copied from the app bundle on every launch so it stays in sync with the running DoomCoder version. Hook configs always reference this stable path so they survive app relocations.

### Hook config formats

| Agent | Format |
|---|---|
| Claude Code | `settings.json` — nested `hooks.PostToolUse` / `hooks.Stop` matchers |
| Cursor | `hooks.json` — `version: 1`, command-only |
| VS Code Copilot | `doomcoder.json` in `~/.copilot/vscode-hooks/`, registered via `chat.hookFilesLocations` in each variant's `settings.json` |
| Copilot CLI | `doomcoder.json` in `~/.copilot/hooks/` — global, all 13 events |
| Windsurf | `hooks.json` — command-only |
| Codex CLI | `hooks.json` + `codex_hooks = true` feature flag in `config.toml` |

### Hook pipeline

```
Agent fires hook
  → dc-hook binary runs
    → writes JSON envelope to Unix socket at ~/Library/Application Support/DoomCoder/hook.sock
      → DoomCoder receives envelope
        → normalizes event → writes to SQLite (events.sqlite)
          → dispatches macOS notification
            → pushes to CloudKit (→ iPhone companion)
```

### Data storage

| Data | Location | Retention |
|---|---|---|
| Hook events (SQLite) | `~/Library/Application Support/DoomCoder/events.sqlite` | 7 days |
| Notification history | Same database | 7 days |
| Log files | `~/Library/Logs/DoomCoder/` | 7 days |
| User preferences | `UserDefaults` (standard) | Persistent |
| CloudKit sync state | Private iCloud container | Persistent |

### Privacy

DoomCoder collects no analytics, sends no data to any server, and has no telemetry. All data stays on your Mac and in your private iCloud container. See [PRIVACY.md](PRIVACY.md) for details.
