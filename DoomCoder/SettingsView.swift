import SwiftUI

// Settings window: Launch at Login and global hotkey (⌥Space) with Accessibility permission flow.
struct SettingsView: View {
    @Bindable var sleepManager: SleepManager

    var body: some View {
        Form {
            Section("General") {
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
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
    }
}
