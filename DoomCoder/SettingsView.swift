import SwiftUI

struct SettingsView: View {
    @Bindable var sleepManager: SleepManager

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { sleepManager.isLaunchAtLoginEnabled },
                    set: { _ in sleepManager.toggleLaunchAtLogin() }
                ))
            }

            Section("Global Shortcut") {
                LabeledContent("Toggle shortcut") {
                    Text("⌥ Space")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Accessibility") {
                    if sleepManager.hasAccessibilityPermission {
                        Label("Access granted", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Access") {
                            sleepManager.requestAccessibilityPermission()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                    }
                }

                if !sleepManager.hasAccessibilityPermission {
                    Text("Required for the ⌥ Space global shortcut. After clicking Grant Access, open System Settings → Privacy & Security → Accessibility and enable Doom Coder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Screen Off Mode") {
                Stepper(value: $sleepManager.screenOffRearmMinutes, in: 1...60) {
                    LabeledContent("Re-sleep display after") {
                        Text("\(sleepManager.screenOffRearmMinutes) min idle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 8)
    }
}
