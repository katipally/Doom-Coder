import SwiftUI

struct SettingsView: View {
    @Bindable var sleepManager: SleepManager
    @Environment(\.openWindow) private var openWindow

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

            Section("Agents") {
                Toggle("Redact prompt text in local history", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "doomcoder.agents.redact") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "doomcoder.agents.redact") }
                ))
                LabeledContent("ntfy topic") {
                    Text(NtfyTopic.getOrCreate())
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Open Configure Agents…") {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        openWindow(id: "configureAgents")
                    }
                    Button("Reveal Logs") { NSWorkspace.shared.open(AgentLogDir.url) }
                    Button("Regenerate ntfy topic") { _ = NtfyTopic.regenerate() }
                }
                .buttonStyle(.bordered)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 8)
    }
}
