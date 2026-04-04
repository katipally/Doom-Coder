import SwiftUI

struct MenuBarView: View {
    @Bindable var sleepManager: SleepManager
    var updaterViewModel: CheckForUpdatesViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Toggle
        Button {
            sleepManager.toggle()
        } label: {
            HStack {
                Image(systemName: sleepManager.isActive ? "bolt.fill" : "bolt.slash.fill")
                Text(sleepManager.isActive ? "Disable Doom Coder" : "Enable Doom Coder")
            }
        }

        if sleepManager.isActive, !sleepManager.elapsedTimeString.isEmpty {
            Text(sleepManager.elapsedTimeString)
                .foregroundStyle(.secondary)
        }

        Divider()

        // Mode Picker
        Menu("Mode: \(sleepManager.mode.displayName)") {
            Button {
                sleepManager.mode = .full
            } label: {
                HStack {
                    Text("⚡ Full Mode — screen stays at full brightness")
                    if sleepManager.mode == .full { Image(systemName: "checkmark") }
                }
            }

            Button {
                sleepManager.mode = .autoDim
            } label: {
                HStack {
                    Text("🌙 Auto-Dim — dims screen when idle, restores on activity")
                    if sleepManager.mode == .autoDim { Image(systemName: "checkmark") }
                }
            }
        }

        if sleepManager.isDimmed {
            Text("💡 Screen dimmed — move mouse to restore")
                .foregroundStyle(.secondary)
        }

        // Auto-Dim Settings (only in Auto-Dim mode)
        if sleepManager.mode == .autoDim {
            Divider()
            Menu("Auto-Dim Settings") {
                Section("Idle Timeout") {
                    ForEach([2, 5, 10], id: \.self) { mins in
                        Button {
                            sleepManager.idleTimeoutMinutes = mins
                        } label: {
                            HStack {
                                Text("\(mins) minutes")
                                if sleepManager.idleTimeoutMinutes == mins {
                                    Image(systemName: "checkmark")
                                }
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
                                if sleepManager.dimBrightnessPercent == pct {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }

        Divider()

        // Session Timer
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
                        if sleepManager.sessionTimerHours == hours {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        if let remaining = sleepManager.sessionTimerRemainingText {
            Text(remaining)
                .foregroundStyle(.secondary)
        }

        Divider()

        // Thermal State
        Text("System: \(sleepManager.thermalStateText)")

        Divider()

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
}
