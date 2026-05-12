import SwiftUI

struct SettingsView: View {
    @Bindable var sleepManager: SleepManager
    @Environment(\.openWindow) private var openWindow
    @State private var cloudKitTestResult: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { sleepManager.isLaunchAtLoginEnabled },
                    set: { _ in sleepManager.toggleLaunchAtLogin() }
                ))
            }

            Section("Global Shortcut") {
                LabeledContent("Open DoomCoder") {
                    Text(GlobalHotkey.shared.current.descriptionForUI)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if GlobalHotkey.shared.conflictDetected {
                    Label("Another app may be using this shortcut. It won't fire until you change it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Text("Works anywhere — no extra permission needed.")
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
                HStack {
                    Button("Open Configure Agents…") {
                        NSApplication.shared.activate()
                        openWindow(id: "configureAgents")
                    }
                    Button("Reveal Logs") { NSWorkspace.shared.open(AgentLogDir.url) }
                }
                .buttonStyle(.bordered)
            }

            Section("Updates") {
                Toggle("Join Beta Channel", isOn: Binding(
                    get: { FeatureFlags.joinBetaChannel },
                    set: { FeatureFlags.joinBetaChannel = $0 }
                ))
                Text("Receive pre-release builds for early access to new features. Stable releases are always available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("iOS Companion (Beta)") {
                Toggle("Enable CloudKit sync", isOn: Binding(
                    get: { FeatureFlags.cloudKitEnabled },
                    set: { FeatureFlags.cloudKitEnabled = $0; SettingsSyncer.shared.pushLocal() }
                ))
                Toggle("Minimal Mode (strip prompt + tool details)", isOn: Binding(
                    get: { FeatureFlags.minimalMode },
                    set: { FeatureFlags.minimalMode = $0; SettingsSyncer.shared.pushLocal() }
                ))
                HStack {
                    Button("Send test event") {
                        cloudKitTestResult = "Sending…"
                        Task {
                            let result = await CloudKitPublisher.shared.sendTestEvent()
                            switch result {
                            case .success(let name): cloudKitTestResult = "OK · \(name)"
                            case .failure(let err): cloudKitTestResult = "Failed · \(err.localizedDescription)"
                            }
                        }
                    }
                    .disabled(!FeatureFlags.cloudKitEnabled)
                    if let r = cloudKitTestResult {
                        Text(r).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                Text("Requires iCloud sign-in. iOS app launches in 3.0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 8)
    }
}
