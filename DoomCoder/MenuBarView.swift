import SwiftUI

struct MenuBarView: View {
    @Bindable var sleepManager: SleepManager
    var updaterViewModel: CheckForUpdatesViewModel
    @Bindable var appDetector: AppDetector
    @Bindable var agentStatus: AgentStatusManager
    @Environment(\.openWindow) private var openWindow

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

        Divider()

        // ── Active Agent Sessions ────────────────────────────────────────────
        if !agentStatus.sessions.isEmpty {
            Menu("Agents: \(agentStatus.sessions.count) live") {
                ForEach(agentStatus.sessions) { s in
                    let label = "\(s.displayName) — \(agentStateText(s.state))\(s.repoName.map { " · \($0)" } ?? "")"
                    Button(label) {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        openWindow(id: "settings")
                    }
                }
            }
        }

        // ── Active Apps ───────────────────────────────────────────────────────
        Button("Active Apps…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "active-apps")
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

    private func openGuide(_ filename: String) {
        let url = URL(string: "https://github.com/katipally/Doom-Coder/blob/main/guide/\(filename)")!
        NSWorkspace.shared.open(url)
    }
}

