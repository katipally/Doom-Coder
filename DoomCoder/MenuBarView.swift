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
            HStack {
                Image(systemName: sleepManager.isActive ? "bolt.fill" : "bolt.slash.fill")
                Text(sleepManager.isActive ? "Disable Doom Coder" : "Enable Doom Coder")
            }
        }

        // Status lines
        if sleepManager.isActive, !sleepManager.elapsedTimeString.isEmpty {
            Text(sleepManager.elapsedTimeString).foregroundStyle(.secondary)
        }
        if let countdown = sleepManager.screenOffCountdown {
            Text("🌑 Screen turns off in \(countdown)s…").foregroundStyle(.secondary)
        }
        if sleepManager.isScreenOff {
            Text("🌑 Screen off — move mouse or press any key").foregroundStyle(.secondary)
        }
        if sleepManager.isDimmed {
            Text("💡 Screen dimmed — move mouse to restore").foregroundStyle(.secondary)
        }

        // Fn+F1 hint
        if sleepManager.hasAccessibilityPermission {
            Text("Fn+F1 to toggle").foregroundStyle(.tertiary)
        }

        Divider()

        // ── Mode Picker ─────────────────────────────────────
        Menu("Mode: \(sleepManager.mode.displayName)") {
            ForEach(DoomCoderMode.allCases, id: \.self) { m in
                Button {
                    sleepManager.mode = m
                } label: {
                    HStack {
                        Text(modeLabel(m))
                        Spacer()
                        if sleepManager.mode == m { Image(systemName: "checkmark") }
                    }
                }
            }
        }

        // ── Auto-Dim Settings ────────────────────────────────
        if sleepManager.mode == .autoDim {
            Menu("Auto-Dim Settings") {
                Section("Idle Timeout") {
                    ForEach([2, 5, 10], id: \.self) { mins in
                        Button {
                            sleepManager.idleTimeoutMinutes = mins
                        } label: {
                            HStack {
                                Text("\(mins) minutes")
                                if sleepManager.idleTimeoutMinutes == mins { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section("Dim Level") {
                    ForEach([5, 10, 20], id: \.self) { pct in
                        Button {
                            sleepManager.dimBrightnessPercent = pct
                        } label: {
                            HStack {
                                Text("\(pct)%")
                                if sleepManager.dimBrightnessPercent == pct { Image(systemName: "checkmark") }
                            }
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
                        Button {
                            sleepManager.screenOffRearmMinutes = mins
                        } label: {
                            HStack {
                                Text("\(mins) minutes")
                                if sleepManager.screenOffRearmMinutes == mins { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
        }

        Divider()

        // ── Session Timer ────────────────────────────────────
        Menu("Session Timer") {
            Button {
                sleepManager.sessionTimerHours = 0
            } label: {
                HStack {
                    Text("Off")
                    if sleepManager.sessionTimerHours == 0 { Image(systemName: "checkmark") }
                }
            }
            ForEach([1, 2, 4, 8], id: \.self) { hours in
                Button {
                    sleepManager.sessionTimerHours = hours
                } label: {
                    HStack {
                        Text("\(hours)h")
                        if sleepManager.sessionTimerHours == hours { Image(systemName: "checkmark") }
                    }
                }
            }
        }

        if let remaining = sleepManager.sessionTimerRemainingText {
            Text(remaining).foregroundStyle(.secondary)
        }

        Divider()

        // ── Thermal State ─────────────────────────────────────
        Text("System: \(sleepManager.thermalStateText)")

        // ── Detected Apps ────────────────────────────────────
        if !appDetector.detectedApps.isEmpty {
            Divider()
            Section("Detected Apps") {
                ForEach(appDetector.detectedApps) { app in
                    Text(appStatusLine(app))
                        .foregroundStyle(app.isRunning ? .primary : .secondary)
                }
            }
        }

        Divider()

        // ── Settings ──────────────────────────────────────────
        // Launch at Login toggle
        Button {
            sleepManager.toggleLaunchAtLogin()
        } label: {
            HStack {
                Text("Launch at Login")
                Spacer()
                if sleepManager.isLaunchAtLoginEnabled { Image(systemName: "checkmark") }
            }
        }

        // Accessibility permission for Fn+F1 hotkey
        if !sleepManager.hasAccessibilityPermission {
            Button("Grant Accessibility (enable Fn+F1)") {
                sleepManager.requestAccessibilityPermission()
            }
        }

        Button("Check for Updates...") {
            updaterViewModel.checkForUpdates()
        }
        .disabled(!updaterViewModel.canCheckForUpdates)

        Button("About Doom Coder...") {
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

    private func modeLabel(_ mode: DoomCoderMode) -> String {
        switch mode {
        case .full:      return "⚡ Full Mode — screen stays fully on"
        case .autoDim:   return "🌙 Auto-Dim — dims screen when idle"
        case .screenOff: return "🌑 Screen Off — turns off display, Mac stays awake"
        }
    }

    private func appStatusLine(_ app: TrackedApp) -> String {
        if app.isRunning, let cpu = app.cpuPercent {
            let cpuStr = cpu < 1.0 ? "idle" : String(format: "%.0f%% CPU", cpu)
            return "✅ \(app.displayName) — \(cpuStr)"
        } else if app.isRunning {
            return "✅ \(app.displayName) — running"
        } else {
            return "⚫ \(app.displayName)"
        }
    }
}

