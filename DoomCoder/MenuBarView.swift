import SwiftUI

struct MenuBarView: View {
    @Bindable var sleepManager: SleepManager
    var updaterViewModel: CheckForUpdatesViewModel
    @Bindable var agentStatus: AgentStatusManager
    @Environment(\.openWindow) private var openWindow

    // Rescanned every time the menu appears (cheap — ~50–80 ms).
    @State private var scanner = RunningAgentScanner()

    var body: some View {
        // ── Toggle ──────────────────────────────────────────────────────────
        Button {
            sleepManager.toggle()
        } label: {
            Label(
                sleepManager.isActive ? "Disable Doom Coder" : "Enable Doom Coder",
                systemImage: sleepManager.isActive ? "bolt.fill" : "bolt.slash.fill"
            )
        }

        // ── Status lines (only when active) ─────────────────────────────────
        if sleepManager.isActive, !sleepManager.elapsedTimeString.isEmpty {
            Text(sleepManager.elapsedTimeString)
                .foregroundStyle(.secondary)
        }
        if let countdown = sleepManager.screenOffCountdown {
            Text("Display off in \(countdown)s")
                .foregroundStyle(.secondary)
        }
        if sleepManager.isScreenOff {
            Text("Display off — move mouse to wake")
                .foregroundStyle(.secondary)
        }

        Divider()

        // ── Mode ─────────────────────────────────────────────────────────────
        Menu("Mode: \(sleepManager.mode.displayName)") {
            ForEach(DoomCoderMode.allCases, id: \.self) { m in
                Button(modeLabel(m, selected: sleepManager.mode == m)) {
                    sleepManager.mode = m
                }
            }
        }

        Divider()

        // ── Session Timer ─────────────────────────────────────────────────────
        Menu("Session Timer") {
            Button(checkLabel(sleepManager.sessionTimerHours == 0, "Off")) {
                sleepManager.sessionTimerHours = 0
            }
            ForEach([1, 2, 4, 8], id: \.self) { hours in
                Button(checkLabel(sleepManager.sessionTimerHours == hours,
                                  "\(hours) \(hours == 1 ? "hour" : "hours")")) {
                    sleepManager.sessionTimerHours = hours
                }
            }
        }
        if let remaining = sleepManager.sessionTimerRemainingText {
            Text(remaining)
                .foregroundStyle(.secondary)
        }

        // ── Agent Tracking header ────────────────────────────────────────────
        Divider()
        Button {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "agent-tracking")
        } label: {
            Label(agentStatusHeader, systemImage: agentStatusIcon)
        }

        // "Watch this agent" submenu — the primary v1.4 UX. Lists detected
        // running agents (both confirmed sessions and scanner candidates)
        // with a checkmark on the one the user is currently watching.
        Menu("Watch this agent") {
            let entries = watchMenuEntries()
            if entries.isEmpty {
                Text("No agents detected")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.key) { entry in
                    Button(checkLabel(agentStatus.watchedSessionKey == entry.key, entry.label)) {
                        agentStatus.watchedSessionKey = entry.key
                    }
                }
            }
            Divider()
            if !agentStatus.watchedSessionKey.isEmpty {
                Button("Stop watching (receive all)") {
                    agentStatus.watchedSessionKey = ""
                }
            } else {
                Text("Watching all agents")
                    .foregroundStyle(.secondary)
            }
            Button("Rescan") {
                scanner.scan()
            }
        }
        .onAppear { scanner.scan() }

        if !agentStatus.sessions.isEmpty {
            ForEach(agentStatus.sessions.prefix(3)) { s in
                Text("  \(s.displayName) — \(agentStateText(s.state))\(s.repoName.map { " · \($0)" } ?? "")")
                    .foregroundStyle(.secondary)
            }
        }

        Divider()

        // ── Settings / Updates / About ────────────────────────────────────────
        Button("Settings…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }

        Button("Check for Updates…") {
            updaterViewModel.checkForUpdates()
        }
        .disabled(!updaterViewModel.canCheckForUpdates)

        Button("About Doom Coder…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "about")
        }

        // ── Help / Guides ────────────────────────────────────────────────────
        Menu("Help") {
            Button("Agent Setup Guide") {
                openGuide("agent-setup.md")
            }
            Button("iPhone Notifications Guide") {
                openGuide("iphone-notifications.md")
            }
            Button("Hooks Reference") {
                openGuide("hooks-reference.md")
            }
            Button("Troubleshooting") {
                openGuide("troubleshooting.md")
            }
            Divider()
            Button("Report an Issue") {
                NSWorkspace.shared.open(URL(string: "https://github.com/katipally/Doom-Coder/issues/new")!)
            }
        }

        Divider()

        Button("Quit Doom Coder") {
            sleepManager.disable()
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Helpers

    private func checkLabel(_ selected: Bool, _ title: String) -> String {
        selected ? "✓  \(title)" : "    \(title)"
    }

    private func modeLabel(_ mode: DoomCoderMode, selected: Bool) -> String {
        let prefix = selected ? "✓  " : "    "
        switch mode {
        case .full:      return "\(prefix)Full Mode — screen stays on"
        case .screenOff: return "\(prefix)Screen Off — display sleeps, Mac awake"
        }
    }

    private func agentStateText(_ state: AgentSession.State) -> String {
        switch state {
        case .active:  return "working"
        case .waiting: return "waiting"
        case .errored: return "error"
        case .done:    return "done"
        }
    }

    private var agentStatusHeader: String {
        if agentStatus.isAnyAgentActive {
            return "Open Agent Tracking… (\(agentStatus.sessions.count) live)"
        }
        return "Open Agent Tracking…"
    }

    private var agentStatusIcon: String {
        agentStatus.isAnyAgentActive ? "circle.fill" : "circle"
    }

    private func openGuide(_ filename: String) {
        let url = URL(string: "https://github.com/katipally/Doom-Coder/blob/main/guide/\(filename)")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Watch menu

    // Row shown in the "Watch this agent" submenu. `key` is what we persist
    // into AgentStatusManager.watchedSessionKey — either a live session id,
    // or a synthetic scanner id (e.g. "copilot-cli:pid:4711"). Both flow
    // through the same gate in deliver(), so unknown scanner keys behave as
    // "watch nothing yet" until a matching hook arrives.
    private struct WatchEntry {
        let key: String
        let label: String
    }

    private func watchMenuEntries() -> [WatchEntry] {
        var out: [WatchEntry] = []
        var seen: Set<String> = []

        // 1) Confirmed live sessions first — these have actually emitted
        //    events, so we trust their ids directly.
        for s in agentStatus.sessions {
            let folder = s.repoName ?? "—"
            let label = "● \(s.displayName) · \(folder) · \(agentStateText(s.state))"
            if seen.insert(s.id).inserted {
                out.append(WatchEntry(key: s.id, label: label))
            }
        }

        // 2) Scanner candidates the user can pre-select before any hook
        //    fires. We key these by a stable synthetic id so that once a
        //    real event arrives its sessionKey matches this one too.
        for inst in scanner.instances {
            if seen.contains(inst.id) { continue }
            let sub = inst.subtitle.isEmpty ? "—" : inst.subtitle
            let label = "○ \(inst.displayName) · \(sub)"
            out.append(WatchEntry(key: inst.id, label: label))
            seen.insert(inst.id)
        }
        return Array(out.prefix(8))
    }
}
