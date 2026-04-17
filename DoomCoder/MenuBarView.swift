import SwiftUI

struct MenuBarView: View {
    @Bindable var sleepManager: SleepManager
    var updaterViewModel: CheckForUpdatesViewModel
    @Bindable var agentStatus: AgentStatusManager
    @Environment(\.openWindow) private var openWindow
    @State private var didCheckOnboarding = false

    var body: some View {
        let _ = presentOnboardingIfNeeded()
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

        // ── Configure Agents / Track ─────────────────────────────────────────
        Divider()
        Button {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "configure")
        } label: {
            Label(agentStatusHeader, systemImage: agentStatusIcon)
        }

        // Track submenu — v1.8. Per-agent toggles (no single-select, no "All").
        // Lists only agents the user has already *configured*. Empty list
        // shows a hint that nudges them into the Configure window.
        Menu("Track") {
            let configured = agentStatus.configuredAgents()
            if configured.isEmpty {
                Text("No configured agents yet")
                    .foregroundStyle(.secondary)
                Button("Open Configure Agents…") {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "configure")
                }
            } else {
                ForEach(configured, id: \.id) { info in
                    Button(checkLabel(agentStatus.watchedAgentIds.contains(info.id),
                                      info.displayName)) {
                        if agentStatus.watchedAgentIds.contains(info.id) {
                            agentStatus.watchedAgentIds.remove(info.id)
                        } else {
                            agentStatus.watchedAgentIds.insert(info.id)
                        }
                    }
                }
                Divider()
                Button("Turn all off") {
                    agentStatus.watchedAgentIds.removeAll()
                }
                .disabled(agentStatus.watchedAgentIds.isEmpty)
            }
        }

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

        Button("Doctor…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "doomcoder-doctor")
        }

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
            Button("MCP Reference") {
                openGuide("mcp-reference.md")
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
        case .screenOn:  return "\(prefix)Screen On — display stays on, Mac awake"
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
            return "Configure Agents… (\(agentStatus.sessions.count) live)"
        }
        return "Configure Agents…"
    }

    private var agentStatusIcon: String {
        agentStatus.isAnyAgentActive ? "circle.fill" : "circle"
    }

    private func openGuide(_ filename: String) {
        let url = URL(string: "https://github.com/katipally/Doom-Coder/blob/main/guide/\(filename)")!
        NSWorkspace.shared.open(url)
    }

    private func presentOnboardingIfNeeded() {
        guard !didCheckOnboarding else { return }
        didCheckOnboarding = true
        let key = "dc.onboardingCompleted"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "onboarding")
        }
    }
}
