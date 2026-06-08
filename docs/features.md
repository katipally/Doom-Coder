# Doom Code — Full Feature Reference

This document covers every feature, setting, and behavior in DoomCode. Each section maps to a place in the UI. Hover the **ⓘ** icons in the app for inline summaries.

---

## Menu bar panel

The panel opens when you click the Doom Code icon in the menu bar, or by pressing the global hotkey (default **⌥ Space**).

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
| **Off** | macOS manages sleep normally. Doom Code holds no IOPMAssertion. |
| **On** | Always holds the sleep assertion. Choose a screen mode and optional session timer below. |
| **Auto** | Holds the assertion while any tracked agent is actively working (running, waiting for input, or waiting for approval). Releases after a 5-minute grace once all agents are idle. Respects per-agent tracking toggles — agents toggled off are excluded. |

#### Screen mode (when Keep-Awake is On)

| Mode | Behavior |
|---|---|
| **Screen On** | Display stays fully lit the whole time. Mac never sleeps. |
| **Screen Off** | Display sleeps after a short delay; Mac CPU stays awake. Saves power and reduces screen burn. When you move the mouse the display wakes; Doom Code re-sleeps it after the re-arm interval. |

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
- **⚠ warning badge** — appears if Doom Code detects that the installed hook config has drifted from what it wrote (e.g. another tool edited it). Select the agent and click **Repair**.
- **✓ checkmark** — confirms hooks are installed.

### Agent detail pane

#### Detection

Shows whether the agent app/CLI is installed and its detected version. Click **Re-scan** after installing or updating an agent.

#### What you'll be notified about

The card lists the notification categories this agent can emit, grouped for clarity. Tap **Edit** to turn individual categories on or off; only categories the agent actually emits are shown.

| Group | Categories |
|---|---|
| **Important** | Completed, Failed, Waiting for approval, Waiting for input |
| **Activity** | Session started, Tool calls, Sub-agent activity, File edits, Thinking, Prompt sent |
| **Housekeeping** | Context compaction, Background tasks |

The approval/permission categories expand into a per-tool palette (shell, file edits, MCP, etc.) so you can be alerted before some tool types but not others.

**Auto-accept handling.** Copilot CLI, Cursor, and Windsurf fire a permission hook *before* their own allowlist auto-approves. Doom Code waits an **approval debounce window** (default 0.8s, adjustable 0.5-3s in the Settings tab) for proof the tool ran before alerting, so auto-approved actions never spam you. Live status stays instant; only the alert is deferred. Agents with reliable hooks (Claude Code, VS Code Copilot, Codex) alert immediately.

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

Sends a synthetic test event through the full hook pipeline and waits for Doom Code to receive it. If the round-trip succeeds, the doctor shows the event in the Live Events panel. If it times out, the doctor reports where the pipeline broke.

#### Live Events

Real-time stream of hook events received from this agent. Events auto-scroll to the bottom. Click an event to expand the JSON payload. Click **Clear** to reset the stream.

---

### Connections tab

Where notifications get delivered, and the devices connected to this Mac. One global **mac + iPhone** channel setting applied to all agents. (Per-agent channel overrides were removed; per-agent control now lives in the "What you'll be notified about" categories card.)

#### Connected Devices

Real, symmetric presence for your companion devices — mirroring how the iOS app shows your Mac's status. Each iPhone or iPad running the Doom Code Companion publishes a periodic heartbeat to your private iCloud container; this Mac reads it and shows each device as **Connected** (green) when seen within the last 10 minutes, or **Last seen X ago** otherwise. When no device has checked in, a **Set up iPhone or iPad** call-to-action links to the App Store.

#### Permission Status

Shows whether macOS notifications are authorized. Click **Allow Notifications** or **Open Settings** to grant/restore permission.

#### macOS notifications

Toggle on to receive banner notifications on your Mac. Click **Test** to send a test notification immediately.

#### iPhone / iPad (iCloud)

Toggle on to mirror notifications to the Doom Code Companion iOS app via your private iCloud container.

**iCloud status indicator** — must show green ("Connected to iCloud as…") for iPhone mirroring to work. If it stays grey, check that you're signed into iCloud in System Settings and that iCloud Drive is enabled.

Click **Test** to send a test push to your iPhone.

[Get Doom Code Companion on the App Store](https://apps.apple.com/app/doomcoder-companion/id6772514212)

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
| **Launch at Login** | Registers Doom Code as a login item via `SMAppService`. |
| **Open Doom Code shortcut** | The global hotkey that opens the panel from anywhere. Default: ⌥ Space. Displayed read-only; change it in the field (coming soon: in-UI rebinding). |

#### Screen Off

| Setting | Default | Description |
|---|---|---|
| **Re-sleep display after** | 5 min | After moving the mouse wakes the display in Screen Off mode, Doom Code re-sleeps it after this many idle minutes. Range: 1–60 minutes. |

#### Session Lifecycle

| Setting | Default | Description |
|---|---|---|
| **Auto-revert completed sessions** | 30 s | How long the "completed" or "failed" badge stays on an agent row before it reverts to "idle". Range: 10–120 seconds. |

#### Notifications & Privacy

| Setting | Default | Description |
|---|---|---|
| **Redact prompt text in local history** | On | Hides agent prompt and response content in the Logs view and event history. Event type, timing, and status are still recorded. |

#### Diagnostics

**Reveal Logs** — opens `~/Library/Logs/DoomCode/` in Finder. Log files are named `doomcoder-YYYY-MM-DD.log` and kept for 7 days.

#### AI

The engine that powers prompt **Enhance**, now a section within Settings (no separate sidebar tab).

| Setting | Description |
|---|---|
| **Engine** | **On-device** (Apple Intelligence, fully local) or **My API key** (BYOK provider). |
| **Provider / API key / Model** | When using your own key, pick a provider, paste the key (**Save & test key** validates it and fetches available models), and choose a model. |

On-device requires a supported Mac with Apple Intelligence enabled; otherwise the section explains why it's unavailable. Prompts and notes are stored only on this Mac — nothing is synced. On-device stays fully local; with a provider key, prompt text is sent to the chosen provider over HTTPS only when you tap Enhance.

---

## Prompts and Notes

A lightweight toolbox window. Both panes focus the editor on open so a first-time user can start typing immediately.

### Mac Prompts

The Prompts pane is a chat-style workspace. Type or paste a prompt in the input bar and press send. The AI rewrites it into a clear, structured version and streams the result directly into the conversation view. Each session is saved automatically.

- **Library button** -- opens a curated collection of ready-made prompts grouped by category. Open any entry into the composer or copy it to the clipboard.
- **History button** -- shows saved conversations. Open a previous session to continue it or start fresh with the New Chat button.
- **Enhance with AI** -- uses the engine configured in Settings ▸ AI (on-device Apple Intelligence or your own API key). Writing, copying, and browsing the library never require AI.

### Mac Notes

On-device notes with title, body, tasks, reminders, and pinning, all local to this Mac.

| Feature | Description |
|---|---|
| **Title** | An explicit title field at the top of the editor. |
| **Body** | Freeform note text. |
| **Tasks** | An inline checklist -- add, check off, and remove to-dos right inside the note. |
| **Reminder** | A Remind me toggle with a date/time picker schedules a local notification. Permission is requested only when you first set one. |
| **Pin / Copy / To Prompt / Delete** | Actions in the editor bottom bar. Pinned notes sort to the top. |

Search matches titles, body, and task text.

---

## Track Agents window

Accessible from the Agent Tracking card in the main panel.

- **Per-agent toggle** — disable notifications for a specific agent without uninstalling its hooks. Events still land in the event store.
- **Paused** — pauses all agent notifications immediately. This is an **in-memory flag** — it resets every time Doom Code is relaunched. The sleep blocker keeps running while paused.
- **Reveal logs** — opens the log directory in Finder.

---

## Global hotkey

Default: **⌥ Space**. Works system-wide without Accessibility permission (uses Carbon `RegisterEventHotKey`, the same mechanism as Spotlight).

If the shortcut conflicts with another app, a banner appears in the panel with a **Fix** link to the Settings pane.

---

## iPhone and iPad companion

**Doom Code Companion** (iOS 26+) is a **standalone app that is fully usable on first launch with no setup** -- no Mac, no iCloud pairing, and no API key required. Connecting a Mac is an optional enhancement, not a requirement.

### Works with zero setup (no Mac, no key)

**Prompts tab** -- a chat-style prompt workspace. Type a prompt and send it; the AI rewrites it into a clear, structured version and streams the reply into the conversation view. Each conversation is saved automatically.

- **History button** (toolbar) -- opens the list of saved conversations. Tap any entry to resume it, or use the New Chat button to start fresh.
- **Library button** (toolbar) -- opens the curated prompt library: write tests, refactor, explain an error, code review, debug, docstrings, commit messages, regex, SQL, API design, performance, security review, and more. Tap any entry to copy it or open it in the chat. The library works with no AI and no Mac.
- **Browse prompt library button** -- shown on the empty state when no conversation is open. Opens the library directly so new users can explore without needing to configure anything.

**Notes tab** -- on-device notes with pinning, inline checklists, search, reminders (local notifications), and a "Turn into prompt" action.

**Settings tab** -- choose the AI engine (on-device Apple Intelligence or your own API key), manage notifications, and pair or unpair a Mac.

### Optional AI (Enhance)

Prompt Enhance is a bonus that uses either Apple on-device model or your own provider key (BYOK). If on-device AI is not available (unsupported device, Apple Intelligence disabled), the app shows clear guidance with a link to Settings, and everything else keeps working.

### Optional Mac connection (mirroring)

Sign into the same iCloud account on your Mac and iPhone, then enable iPhone / iPad in Configure > Connections. The companion then mirrors every Mac notification in 1-5 seconds via your private iCloud container (CloudKit) -- no third-party server, no API keys, no QR codes.

With a Mac paired you also get the **Dashboard tab**: the live agent list with status dots, per-agent notification history, a 7-day session log, and remote keep-awake and master on/off controls.

---

## Technical details

### dc-hook binary

A small helper binary (`dc-hook`) is installed into `~/Library/Application Support/DoomCoder/dc-hook`. It is copied from the app bundle on every launch so it stays in sync with the running Doom Code version. Hook configs always reference this stable path so they survive app relocations.

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
      → Doom Code receives envelope
        → normalizes event → writes to SQLite (events.sqlite)
          → dispatches macOS notification
            → pushes to CloudKit (→ iPhone companion)
```

### Data storage

| Data | Location | Retention |
|---|---|---|
| Hook events (SQLite) | `~/Library/Application Support/DoomCoder/events.sqlite` | 7 days |
| Notification history | Same database | 7 days |
| Log files | `~/Library/Logs/DoomCode/` | 7 days |
| User preferences | `UserDefaults` (standard) | Persistent |
| CloudKit sync state | Private iCloud container | Persistent |

### Privacy

Doom Code collects no analytics, sends no data to any server, and has no telemetry. All data stays on your Mac and in your private iCloud container. See [privacy.md](privacy.md) for the full policy.
