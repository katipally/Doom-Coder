import SwiftUI

struct MenuBarView: View {
    @Bindable var sleepManager: SleepManager
    var updaterViewModel: CheckForUpdatesViewModel
    @Bindable var appDetector: AppDetector
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // ── Toggle ──────────────────────────────────────────
        Button {
            sleepManager.toggle()
        } label: {
            Label(
                sleepManager.isActive ? "Disable Doom Coder" : "Enable Doom Coder",
                systemImage: sleepManager.isActive ? "bolt.fill" : "bolt.slash.fill"
            )
        }

        // ── Status lines ────────────────────────────────────
        if sleepManager.isActive, !sleepManager.elapsedTimeString.isEmpty {
            Text(sleepManager.elapsedTimeString).foregroundStyle(.secondary)
        }
        if let countdown = sleepManager.screenOffCountdown {
            Text("🌑 Turning off screen in \(countdown)s…").foregroundStyle(.secondary)
        }
        if sleepManager.isScreenOff {
            Text("🌑 Screen is off — move mouse to wake").foregroundStyle(.secondary)
        }
        if sleepManager.isDimmed {
            Text("💡 Screen dimmed — move mouse to restore").foregroundStyle(.secondary)
        }
        if sleepManager.hasAccessibilityPermission {
            Text("Tip: Press Fn+F1 to toggle").foregroundStyle(.tertiary)
        }

        Divider()

        // ── Mode ────────────────────────────────────────────
        Menu("Mode: \(sleepManager.mode.displayName)") {
            ForEach(DoomCoderMode.allCases, id: \.self) { m in
                Button(modeLabel(m, selected: sleepManager.mode == m)) {
                    sleepManager.mode = m
                }
            }
        }

        // ── Auto-Dim Settings ────────────────────────────────
        if sleepManager.mode == .autoDim {
            Menu("Auto-Dim Settings") {
                Section("Idle Timeout") {
                    ForEach([2, 5, 10], id: \.self) { mins in
                        Button(checkLabel(sleepManager.idleTimeoutMinutes == mins, "\(mins) minutes")) {
                            sleepManager.idleTimeoutMinutes = mins
                        }
                    }
                }
                Section("Dim Level") {
                    ForEach([5, 10, 20], id: \.self) { pct in
                        Button(checkLabel(sleepManager.dimBrightnessPercent == pct, "\(pct)%")) {
                            sleepManager.dimBrightnessPercent = pct
                        }
                    }
                }
            }
        }

        // ── Screen-Off Settings ──────────────────────────────
        if sleepManager.mode == .screenOff {
            Menu("Screen-Off Settings") {
                Section("Re-arm after idle") {
                    ForEach([5, 10, 15, 30], id: \.self) { mins in
                        Button(checkLabel(sleepManager.screenOffRearmMinutes == mins, "\(mins) min idle")) {
                            sleepManager.screenOffRearmMinutes = mins
                        }
                    }
                }
            }
        }

        Divider()

        // ── Session Timer ────────────────────────────────────
        Menu("Session Timer") {
            Button(checkLabel(sleepManager.sessionTimerHours == 0, "Off")) {
                sleepManager.sessionTimerHours = 0
            }
            ForEach([1, 2, 4, 8], id: \.self) { hours in
                Button(checkLabel(sleepManager.sessionTimerHours == hours, "\(hours) hours")) {
                    sleepManager.sessionTimerHours = hours
                }
            }
        }
        if let remaining = sleepManager.sessionTimerRemainingText {
            Text(remaining).foregroundStyle(.secondary)
        }

        Divider()

        // ── Thermal ───────────────────────────────────────────
        Text("Thermal: \(sleepManager.thermalStateText)")

        // ── Detected AI Apps ─────────────────────────────────
        if !appDetector.detectedApps.isEmpty {
            Divider()
            Section("AI Apps") {
                ForEach(appDetector.detectedApps) { app in
                    Text(appStatusLine(app))
                        .foregroundStyle(app.isRunning ? .primary : .secondary)
                }
            }
        }

        Divider()

        // ── Options ───────────────────────────────────────────
        Button(checkLabel(sleepManager.isLaunchAtLoginEnabled, "Launch at Login")) {
            sleepManager.toggleLaunchAtLogin()
        }

        if !sleepManager.hasAccessibilityPermission {
            Button("Grant Accessibility (Fn+F1 hotkey)") {
                sleepManager.requestAccessibilityPermission()
            }
        }

        Button("Check for Updates…") {
            updaterViewModel.checkForUpdates()
        }
        .disabled(!updaterViewModel.canCheckForUpdates)

        Button("About Doom Coder…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "about")
        }

        Divider()

        Button("Quit Doom Coder") {
            sleepManager.disable()
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Helpers

    /// Prepends "✓ " to the title when selected — works correctly in both NSMenu and SwiftUI popup styles.
    private func checkLabel(_ selected: Bool, _ title: String) -> String {
        selected ? "✓  \(title)" : "    \(title)"
    }

    private func modeLabel(_ mode: DoomCoderMode, selected: Bool) -> String {
        let prefix = selected ? "✓  " : "    "
        switch mode {
        case .full:      return "\(prefix)⚡ Full Mode — screen always on"
        case .autoDim:   return "\(prefix)🌙 Auto-Dim — dims when idle"
        case .screenOff: return "\(prefix)🌑 Screen Off — display off, Mac awake"
        }
    }

    private func appStatusLine(_ app: TrackedApp) -> String {
        if app.isRunning, let cpu = app.cpuPercent {
            let cpuStr = cpu < 1.0 ? "idle" : String(format: "%.0f%% CPU", cpu)
            return "✅ \(app.displayName)  \(cpuStr)"
        } else if app.isRunning {
            return "✅ \(app.displayName)  running"
        } else {
            return "⚫ \(app.displayName)"
        }
    }
}

