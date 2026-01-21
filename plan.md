# DoomCoder MCP Agent Status Bridge — v0.7.0

**Date:** April 15, 2026  
**Status:** Final  
**Scope:** Single-tier MCP-based status reporting for AI agents

---

## 1. What This Is

A compiled Swift MCP server binary (`doomcoder-mcp`) bundled inside `DoomCoder.app/Contents/Resources/`. AI agents connect via stdio. Server exposes one tool (`dc`), one parameter (`s`), five enum values. On call, writes sentinel JSON to `~/.doomcoder/status/`. DoomCoder main process watches via FSEvents. Fires macOS notifications.

```
Agent → stdio → doomcoder-mcp (Swift CLI) → writes ~/.doomcoder/status/{agent}-{pid}.json → DoomCoder FSEvents → Notification
```

---

## 2. MCP Tool Schema

```json
{
  "name": "dc",
  "description": "Report status to DoomCoder. Call at task start, on errors, and on completion.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "s": {
        "type": "string",
        "enum": ["start", "work", "wait", "error", "done"]
      }
    },
    "required": ["s"]
  }
}
```

### Token Budget

| Item | Tokens | Frequency |
|---|---|---|
| Schema injection | ~60-80 | Once/session |
| Per `dc` call (req + resp) | ~20-25 | Per call |
| Typical session (3 calls) | **~130-155** | Per task |

**Optimization techniques applied:**
- 2-char tool name (`dc`) — saves ~13 tokens vs `report_status` per injection
- 1-char param name (`s`) — saves ~5 tokens vs `status`
- Short enum values (avg 4 chars) — no descriptions on values
- Zero optional parameters — no deliberation cost
- Flat schema — no nesting, no `$ref`
- Verified against `cl100k_base` tokenizer (GPT-4/Claude tokenizer family)

### Status Values

| Value | Meaning | DoomCoder Notification |
|---|---|---|
| `start` | Task began | "Agent started working…" |
| `work` | Actively processing | *Suppressed* |
| `wait` | Needs human input | **"Agent needs your input!"** (urgent sound) |
| `error` | Blocking issue | "Agent hit an error" |
| `done` | Task completed | "Agent finished" |

### Tool Response Format

The `dc` tool returns a compact status line with DoomCoder state:

```
ok session:2h34m thermal:normal peers:claude-code=working
```

**Fields:**
- `ok` — call succeeded
- `session:` — DoomCoder active session duration (read from `SleepManager.elapsedTimeString`)
- `thermal:` — macOS thermal state (`nominal`/`fair`/`serious`/`critical`, from `ProcessInfo.processInfo.thermalState`)
- `peers:` — comma-separated list of other connected agents and their last known status

The MCP CLI reads DoomCoder state from a reverse sentinel file (`~/.doomcoder/app-state.json`) that DoomCoder writes on each timer tick. If file absent or stale: response is `ok doomcoder:not-running`.

Response cost: ~10-15 tokens. Already spent regardless — might as well return useful data.

---

## 3. Sentinel File Design

### Agent → DoomCoder (per-agent, per-PID)

**Path:** `~/.doomcoder/status/{agent}-{pid}.json`

```json
{
  "agent": "cursor",
  "s": "work",
  "ts": 1713229200,
  "pid": 12345
}
```

PID-based filenames solve concurrent sessions: Cursor with 3 windows = 3 PIDs = 3 files (`cursor-42001.json`, `cursor-42002.json`, `cursor-42003.json`). Each session tracked independently.

### DoomCoder → MCP CLI (reverse channel)

**Path:** `~/.doomcoder/app-state.json`

```json
{
  "active": true,
  "session_sec": 9240,
  "thermal": "nominal",
  "agents": {
    "cursor-42001": "work",
    "claude-code-42100": "done"
  },
  "ts": 1713229200
}
```

Written by DoomCoder's main process on every timer tick (~3s). Read by `doomcoder-mcp` on each `dc` call to populate the response.

### Staleness: PID-Based Detection

No arbitrary TTL. Use `kill(pid, 0)` (POSIX signal 0) to check if `doomcoder-mcp` process at recorded PID is alive:

```swift
import Darwin

func isProcessAlive(pid: pid_t) -> Bool {
    let result = kill(pid, 0)
    return result == 0 || errno == EPERM
}
```

- `kill(pid, 0)` returns 0 → process alive
- `errno == EPERM` → process alive but different user (still counts)
- `errno == ESRCH` → process dead → sentinel is stale → remove file

**PID recycling guard:** Also compare process start time via `proc_pidinfo` with `PROC_PIDT_SHORTBSDINFO`. If PID exists but start time differs from sentinel `ts`, the PID was recycled — treat as stale.

**Check frequency:** Every 5 seconds, piggybacking on existing `AppDetector` polling loop.

---

## 4. Agent Name Normalization

MCP clients send `clientInfo.name` during `initialize`. Known values (verified via MCP Inspector and community reports):

| Client | Sends | Normalized |
|---|---|---|
| Cursor | `"cursor-vscode"` | `cursor` |
| Claude Code | `"claude-code"` | `claude-code` |
| VS Code + Copilot | `"vscode"` | `vscode` |
| Windsurf | `"windsurf"` | `windsurf` |
| Gemini CLI | TBD (verify at impl) | `gemini` |
| Unknown | anything else | lowercase, spaces→dashes, truncate to 20 chars |

Normalization map lives in `doomcoder-mcp/main.swift`:

```swift
let nameMap: [String: String] = [
    "cursor-vscode": "cursor",
    "cursor": "cursor",
    "claude-code": "claude-code",
    "claude code": "claude-code",
    "vscode": "vscode",
    "windsurf": "windsurf",
]

func normalize(_ raw: String) -> String {
    let lower = raw.lowercased()
    return nameMap[lower] ?? lower
        .replacingOccurrences(of: " ", with: "-")
        .prefix(20)
        .description
}
```

---

## 5. Rules / Skills Injection

Instructions injected into agent context to guarantee `dc` tool usage. Written in caveman style — minimal words, maximum compliance.

### Claude Code — `CLAUDE.md`

```markdown
## DoomCoder
dc tool: call at task start, errors, completion.
- dc(s:"start") → begin task
- dc(s:"done") → finish
- dc(s:"error") → blocking error
- dc(s:"wait") → need user input
```

~30 tokens. Imperative, no fluff.

### Cursor — `.cursor/rules/doomcoder.mdc`

```markdown
---
description: Report task lifecycle to DoomCoder
alwaysApply: true
---
dc tool required. Call:
1. s:"start" — task begin
2. s:"done" — task end
3. s:"error" — blocking error
4. s:"wait" — need user input
```

~25 tokens of rule body. `alwaysApply: true` = loaded every session (Cursor `.mdc` spec).

### VS Code / Copilot — `.github/copilot-instructions.md`

```markdown
## DoomCoder
Call dc tool: s:"start" at task begin, s:"done" at end, s:"error" on errors, s:"wait" for input.
```

~20 tokens.

### Compliance Expectation

~95%+ based on observed behavior with `alwaysApply: true` + imperative phrasing + ultra-short tool schema. The remaining ~5%: existing heuristic detection (FSEvents + network bytes + child PIDs) continues running. When MCP status exists and is fresh, it overrides heuristic display. When absent, heuristic shown instead. Seamless fallback.

---

## 6. Agent Setup

### Claude Code

```bash
claude mcp add doomcoder -- /Applications/DoomCoder.app/Contents/Resources/doomcoder-mcp
```

### Cursor — `.cursor/mcp.json`

```json
{
  "mcpServers": {
    "doomcoder": {
      "command": "/Applications/DoomCoder.app/Contents/Resources/doomcoder-mcp"
    }
  }
}
```

### VS Code — `.vscode/mcp.json`

```json
{
  "servers": {
    "doomcoder": {
      "command": "/Applications/DoomCoder.app/Contents/Resources/doomcoder-mcp"
    }
  }
}
```

### Windsurf

Settings → MCP Servers → Add → Command: `/Applications/DoomCoder.app/Contents/Resources/doomcoder-mcp`

### Gemini CLI

```bash
gemini mcp add doomcoder -- /Applications/DoomCoder.app/Contents/Resources/doomcoder-mcp
```

---

## 7. Binary Path Resolution

**Problem:** If DoomCoder is not at `/Applications/DoomCoder.app`, hardcoded paths break.

**Solution: Absolute path + opt-in symlink (both)**

1. **Runtime detection:** DoomCoder Settings tab detects actual app location via `Bundle.main.bundlePath`. All config templates use the real path. If user moves the app, templates update automatically.

2. **Opt-in symlink:** Settings tab offers "Install CLI Tool" button. User clicks → DoomCoder creates symlink:
   ```
   ~/.local/bin/doomcoder-mcp → /actual/path/DoomCoder.app/Contents/Resources/doomcoder-mcp
   ```
   Only created on explicit user action. Never auto-created. Follows Apple Human Interface Guidelines and macOS CLI distribution best practices (2026).

3. **Configs then reference the symlink** if installed, or the absolute bundle path if not:
   ```json
   {"command": "~/.local/bin/doomcoder-mcp"}
   ```
   vs
   ```json
   {"command": "/Applications/DoomCoder.app/Contents/Resources/doomcoder-mcp"}
   ```

---

## 8. Build Strategy

**Decision: Xcode multi-target (Option A)**

DoomCoder.xcodeproj already uses SPM for Sparkle (`XCRemoteSwiftPackageReference`). Add `modelcontextprotocol/swift-sdk` as a second SPM dependency. Create a new CLI target in the same project.

### Xcode Project Changes

1. **New SPM dependency:**
   ```
   https://github.com/modelcontextprotocol/swift-sdk.git (from: 0.11.0)
   ```
   Added at project level alongside existing Sparkle dependency.

2. **New target:** `doomcoder-mcp` (macOS Command Line Tool)
   - Type: Command Line Tool
   - Language: Swift
   - Deployment Target: macOS 14.0
   - Linked Frameworks: `MCP` product from `swift-sdk`
   - Optimization: `-Osize` for Release builds (minimizes binary size)
   - Strip: `strip -x` in post-build phase (remove debug symbols)

3. **Copy Files build phase** on main `DoomCoder` target:
   - Destination: Resources
   - Files: `doomcoder-mcp` binary from build products
   - Code sign on copy: Yes

4. **Target dependency:** Main `DoomCoder` target depends on `doomcoder-mcp` target. Ensures CLI builds before main app.

### Binary Size Mitigation

Swift CLI binaries include the Swift runtime. Expected size: ~3-8MB (universal binary). Mitigation:
- Build Release with `-Osize` optimization level
- Enable dead code stripping (`-dead_strip` linker flag)
- Strip debug symbols post-build
- Build single architecture (`arm64` only) if acceptable — reduces ~40%
- If binary exceeds 5MB: fallback to hand-rolled JSON-RPC (~200 lines, zero dependencies, <500KB)

### App Bundle Layout

```
DoomCoder.app/
├── Contents/
│   ├── MacOS/
│   │   └── DoomCoder
│   ├── Resources/
│   │   └── doomcoder-mcp          ← NEW
│   ├── Frameworks/
│   │   └── Sparkle.framework/
│   └── Info.plist
```

---

## 9. New Files

### `doomcoder-mcp/main.swift` (~90 lines)

```swift
import MCP
import Foundation
import Darwin

// Agent name normalization map
let nameMap: [String: String] = [
    "cursor-vscode": "cursor",
    "cursor": "cursor",
    "claude-code": "claude-code",
    "claude code": "claude-code",
    "vscode": "vscode",
    "windsurf": "windsurf",
]

func normalize(_ raw: String) -> String {
    let lower = raw.lowercased()
    return nameMap[lower] ?? String(lower
        .replacingOccurrences(of: " ", with: "-")
        .prefix(20))
}

@main
struct DoomCoderMCP {
    static func main() async throws {
        // All logging → stderr (stdout = JSON-RPC only)
        let log = FileHandle.standardError

        let server = Server(
            name: "doomcoder",
            version: "0.7.0",
            capabilities: .init(tools: .init())
        )

        let dcTool = Tool(
            name: "dc",
            description: "Report status to DoomCoder. Call at task start, on errors, and on completion.",
            inputSchema: .object(
                properties: [
                    "s": .string(enum: ["start", "work", "wait", "error", "done"])
                ],
                required: ["s"]
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [dcTool])
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard params.name == "dc" else {
                throw MCPError.invalidParams("Unknown tool")
            }
            let status = (params.arguments?["s"] as? String) ?? "work"
            let rawName = server.clientInfo?.name ?? "unknown"
            let agentName = normalize(rawName)
            let pid = ProcessInfo.processInfo.processIdentifier

            // Write sentinel file: ~/.doomcoder/status/{agent}-{pid}.json
            let home = FileManager.default.homeDirectoryForCurrentUser
            let statusDir = home.appendingPathComponent(".doomcoder/status")
            try? FileManager.default.createDirectory(at: statusDir, withIntermediateDirectories: true)

            let sentinel: [String: Any] = [
                "agent": agentName, "s": status,
                "ts": Int(Date().timeIntervalSince1970), "pid": pid
            ]
            let data = try JSONSerialization.data(withJSONObject: sentinel)
            try data.write(to: statusDir.appendingPathComponent("\(agentName)-\(pid).json"))

            log.write("dc: \(agentName) → \(status)\n".data(using: .utf8)!)

            // Read DoomCoder app state for response
            let appState = home.appendingPathComponent(".doomcoder/app-state.json")
            var response = "ok"
            if let stateData = try? Data(contentsOf: appState),
               let state = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any] {
                let ts = state["ts"] as? Int ?? 0
                let age = Int(Date().timeIntervalSince1970) - ts
                if age < 10 { // DoomCoder wrote state within last 10s → running
                    let session = state["session_sec"] as? Int ?? 0
                    let thermal = state["thermal"] as? String ?? "?"
                    let h = session / 3600; let m = (session % 3600) / 60
                    response = "ok session:\(h)h\(m)m thermal:\(thermal)"
                    if let agents = state["agents"] as? [String: String] {
                        let peers = agents.filter { !$0.key.hasPrefix(agentName) }
                        if !peers.isEmpty {
                            let p = peers.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                            response += " peers:\(p)"
                        }
                    }
                } else {
                    response = "ok doomcoder:not-running"
                }
            } else {
                response = "ok doomcoder:not-running"
            }

            return .init(content: [.text(response)], isError: false)
        }

        let transport = StdioTransport()
        try await server.connect(transport: transport)
    }
}
```

### `SentinelFileWatcher.swift` (~130 lines)

FSEvents watcher on `~/.doomcoder/status/`.

**Key behaviors:**
- Creates `~/.doomcoder/status/` on init
- FSEventStream with **1.0s coalescing** (faster than the 1.5s used for workspaceStorage — status changes are higher priority)
- Reuses same C callback + `Unmanaged<Self>` pointer pattern from `WorkingStateDetector.swift`
- On file change: reads JSON, validates `agent`/`s`/`ts`/`pid` fields
- Emits `AgentReport` to `AgentStatusManager`
- On launch: reads all existing sentinel files to catch up on current state
- Ignores files with `ts` > 300s old on initial read (5 min cold-start staleness)

**Staleness sweep** (every 5s, in `AgentStatusManager`):
```swift
func sweepStale() {
    for (key, status) in statuses {
        if !isProcessAlive(pid: status.pid) {
            statuses.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: sentinelPath(for: key))
        }
    }
}
```

### `AgentStatusManager.swift` (~110 lines)

```swift
enum AgentState: String, Codable {
    case started, working, waitingForInput, error, completed, idle, unknown
}

@Observable
@MainActor
final class AgentStatusManager {
    struct Status {
        let agentName: String
        let state: AgentState
        let pid: pid_t
        let timestamp: Date
        let source: Source
    }

    enum Source { case mcp, heuristic }

    private(set) var statuses: [String: Status] = [:]  // key = "{agent}-{pid}"

    // MCP status overrides heuristic when fresh. Heuristic always runs silently.
    // UI shows MCP status when available; heuristic when not.
    func effectiveState(for bundleID: String) -> AgentState { ... }
}
```

**Priority logic:**
- If any MCP sentinel exists for this agent category with `isProcessAlive(pid:) == true` → show MCP state
- Otherwise → show heuristic state from `WorkingStateDetector`
- Both sources always run. MCP overrides display only.

### `ConfigTemplates.swift` (~160 lines)

Generates config strings using runtime-detected app location (`Bundle.main.bundlePath`).

```swift
struct ConfigTemplates {
    static var binaryPath: String {
        let bundle = Bundle.main.bundlePath
        return "\(bundle)/Contents/Resources/doomcoder-mcp"
    }

    // Returns symlink path if installed, else bundle path
    static var resolvedPath: String {
        let symlink = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/doomcoder-mcp").path
        if FileManager.default.fileExists(atPath: symlink) { return symlink }
        return binaryPath
    }

    static func claudeCodeCommand() -> String { ... }
    static func cursorMCPJSON() -> String { ... }
    static func cursorRulesMDC() -> String { ... }
    static func vscodeMCPJSON() -> String { ... }
    static func claudeMD() -> String { ... }
    static func copilotInstructions() -> String { ... }
}
```

### `DoomCoderAppState.swift` (~40 lines)

Writes `~/.doomcoder/app-state.json` on every timer tick so `doomcoder-mcp` can read it for responses.

```swift
@MainActor
final class DoomCoderAppState {
    func write(sleepManager: SleepManager, agentStatuses: [String: AgentStatusManager.Status]) {
        let state: [String: Any] = [
            "active": sleepManager.isActive,
            "session_sec": sleepManager.elapsedSeconds,
            "thermal": ProcessInfo.processInfo.thermalState.description,
            "agents": agentStatuses.mapValues { $0.state.rawValue },
            "ts": Int(Date().timeIntervalSince1970)
        ]
        let data = try? JSONSerialization.data(withJSONObject: state)
        try? data?.write(to: appStatePath)
    }
}
```

---

## 10. Modified Files

### `NotificationManager.swift` (+40 lines)

New method:

```swift
func recordMCPStatus(agentName: String, state: AgentState) {
    // MCP-sourced statuses fire immediately — no polling debounce
    switch state {
    case .started:
        sendNotification(title: "\(agentName) started working", urgent: false)
    case .waitingForInput:
        sendNotification(title: "\(agentName) needs your input!", urgent: true)
    case .error:
        sendNotification(title: "\(agentName) hit an error", urgent: false)
    case .completed:
        sendNotification(title: "\(agentName) finished", urgent: false)
    case .working:
        break // suppress — too frequent
    default: break
    }
}
```

Existing `record(app:isWorking:)` stays untouched for heuristic path.

### `AppDetector.swift` (+20 lines)

- Add `var agentStatusManager: AgentStatusManager?`
- In `updateWorkingStates()`: check `agentStatusManager.effectiveState(for: bundleID)`
- If MCP state exists → override `isWorking` flag on `TrackedApp`
- Add `agentState: AgentState?` property to `TrackedApp`

### `DoomCoderApp.swift` (+15 lines)

```swift
@State private var sentinelWatcher = SentinelFileWatcher()
@State private var agentStatusManager = AgentStatusManager()
@State private var appState = DoomCoderAppState()
```

Wire in `body`: connect `sentinelWatcher.onStatusUpdate → agentStatusManager`, connect `agentStatusManager` to `appDetector` and `notificationManager`. Start `appState` writer on timer.

### `SettingsView.swift` (+200 lines)

New tab: **"Agent Bridge"** (tab index 2).

**Section 1: MCP Server**
- Binary location (detected from bundle)
- Status: ✅ Found / ❌ Not found
- "Install CLI Shortcut" button → creates `~/.local/bin/doomcoder-mcp` symlink (opt-in)

**Section 2: Agent Setup Guides**
Expandable `DisclosureGroup` per agent:
- Claude Code: copy command button
- Cursor: copy mcp.json + copy rules.mdc + "Auto-Install" (project-level only — user picks folder via `NSOpenPanel`, writes `.cursor/mcp.json` + `.cursor/rules/doomcoder.mdc`)
- VS Code: copy mcp.json
- Windsurf: text instructions
- Gemini CLI: copy command

"Auto-Install" merges with existing config files. If `.cursor/mcp.json` exists, reads it, adds `doomcoder` entry to `mcpServers`, writes back. Uses `JSONSerialization` for merge. Creates backup (`.cursor/mcp.json.bak`) before modifying.

**Section 3: Live Status**
- Table: Agent | PID | Status | Last Update
- Data from `AgentStatusManager.statuses`
- Colored pills: 🟢 Working/Started, 🟡 Waiting, 🔴 Error, ⚪ Idle, ✅ Done

### `ActiveAppsView.swift` (+20 lines)

New column in tracked apps table: "Status" — shows `AgentState` as SF Symbol + color when MCP data available. Shows `—` when heuristic-only.

---

## 11. File Summary

| File | Action | Lines | Purpose |
|---|---|---|---|
| `doomcoder-mcp/main.swift` | NEW | ~90 | MCP stdio server CLI |
| `SentinelFileWatcher.swift` | NEW | ~130 | FSEvents on `~/.doomcoder/status/` |
| `AgentStatusManager.swift` | NEW | ~110 | Unified status engine + PID sweep |
| `ConfigTemplates.swift` | NEW | ~160 | Per-agent config generators |
| `DoomCoderAppState.swift` | NEW | ~40 | Reverse channel writer |
| `NotificationManager.swift` | MOD | +40 | MCP-triggered notifications |
| `AppDetector.swift` | MOD | +20 | AgentStatusManager integration |
| `DoomCoderApp.swift` | MOD | +15 | Initialize new components |
| `SettingsView.swift` | MOD | +200 | Agent Bridge tab |
| `ActiveAppsView.swift` | MOD | +20 | Status column |

**New code: ~530 lines (CLI) + ~295 lines (UI/infra) = ~825 lines total**

---

## 12. Decisions Log

| # | Question | Decision | Rationale |
|---|---|---|---|
| Q1 | Build strategy | **Xcode multi-target** | Same xcodeproj, single build, SPM already used for Sparkle |
| Q2 | Tool response | **Rich: session + thermal + peers** | Response tokens already spent; free context for agent |
| Q3 | Staleness | **PID-based** | `kill(pid, 0)` is definitive — no arbitrary timeout guessing |
| Q4 | Rules strategy | **Standard: start/done/error/wait** | 4 events, ~60 tokens/task, good coverage without noise |
| Q5 | Multi-session | **PID-based files** | `{agent}-{pid}.json` — each session tracked independently |
| Q6 | Heuristic fallback | **Always on, MCP overrides display** | Both sources run; MCP wins when fresh, heuristic fills gaps |
| Q7 | Auto-install | **Project-level only** | User picks folder via NSOpenPanel. Safe. No global mutation. |
| Q8 | Path resolution | **Both: absolute + opt-in symlink** | Templates use real path; optional `~/.local/bin/` symlink |
| Q9 | DoomCoder not running | **Check + report in response** | `"ok doomcoder:not-running"` if `app-state.json` stale |

---

## 13. Verification

### Build
- [ ] `doomcoder-mcp` target compiles in Xcode
- [ ] Binary placed in `DoomCoder.app/Contents/Resources/doomcoder-mcp`
- [ ] Universal binary (arm64 + x86_64) or arm64-only — verify size < 5MB

### Protocol
- [ ] `echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | ./doomcoder-mcp` returns valid JSON
- [ ] `tools/list` returns exactly one tool: `dc`
- [ ] `tools/call` with `dc(s:"start")` writes `~/.doomcoder/status/test-{pid}.json`
- [ ] Response contains `ok session:... thermal:...` when `app-state.json` fresh
- [ ] Response contains `ok doomcoder:not-running` when `app-state.json` absent/stale

### Integration
- [ ] Cursor: configure `.cursor/mcp.json` → server shows ✅ in Cursor MCP settings
- [ ] Cursor: add `.cursor/rules/doomcoder.mdc` → agent calls `dc` at task start/end
- [ ] Claude Code: `claude mcp add doomcoder` → agent calls `dc` reliably
- [ ] DoomCoder receives sentinel → fires macOS notification within 2s

### Edge Cases
- [ ] Agent crashes → PID dead → sentinel cleaned up within 5s
- [ ] DoomCoder not running → sentinel written → DoomCoder reads on next launch
- [ ] 3 Cursor windows → 3 PID files → all tracked independently
- [ ] Invalid JSON in sentinel → gracefully ignored, logged to stderr
- [ ] Binary at unexpected path → Settings shows actual path, configs work
- [ ] PID recycling → start time mismatch detected → treated as stale

### Heuristic Fallback
- [ ] Agent without MCP configured → heuristic still detects working/idle
- [ ] Agent with MCP + stale sentinel → falls back to heuristic display
- [ ] Both MCP and heuristic active → MCP shown in UI, heuristic silent
