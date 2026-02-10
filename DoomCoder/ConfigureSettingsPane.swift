import SwiftUI
import AppKit

/// Settings pane embedded as the 4th tab of the Configure window. Replaces
/// the standalone `SettingsView` window scene. Every control here backs a
/// real, persistent preference — no stubs.
struct ConfigureSettingsPane: View {
    @Bindable var sleepManager: SleepManager
    @State private var ntfyRegenerated = false
    @State private var autoRevertSeconds: Int = {
        UserDefaults.standard.object(forKey: "doomcoder.session.autoRevertSeconds") as? Int ?? 30
    }()
    @State private var redact: Bool = {
        UserDefaults.standard.object(forKey: "doomcoder.agents.redact") as? Bool ?? true
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.largeTitle.bold())
                    .padding(.top, 8)

                section("General") {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { sleepManager.isLaunchAtLoginEnabled },
                        set: { _ in sleepManager.toggleLaunchAtLogin() }
                    ))
                    Divider()
                    HStack {
                        Text("Open DoomCoder")
                        Spacer()
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

                section("Screen Off") {
                    Stepper(value: $sleepManager.screenOffRearmMinutes, in: 1...60) {
                        HStack {
                            Text("Re-sleep display after")
                            Spacer()
                            Text("\(sleepManager.screenOffRearmMinutes) min idle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                section("Session Lifecycle") {
                    Stepper(value: $autoRevertSeconds, in: 10...120, step: 5) {
                        HStack {
                            Text("Auto-revert completed sessions to idle after")
                            Spacer()
                            Text("\(autoRevertSeconds)s")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: autoRevertSeconds) { _, new in
                        UserDefaults.standard.set(new, forKey: "doomcoder.session.autoRevertSeconds")
                    }
                    Text("How long the badge shows \"completed\" or \"failed\" before reverting to \"idle\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("Notifications & Privacy") {
                    Toggle("Redact prompt text in local history", isOn: $redact)
                        .onChange(of: redact) { _, new in
                            UserDefaults.standard.set(new, forKey: "doomcoder.agents.redact")
                        }
                    Divider()
                    HStack {
                        Text("ntfy topic")
                        Spacer()
                        Text(NtfyTopic.getOrCreate())
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button {
                            _ = NtfyTopic.regenerate()
                            ntfyRegenerated = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                ntfyRegenerated = false
                            }
                        } label: {
                            if ntfyRegenerated {
                                Label("Regenerated", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Text("Regenerate ntfy topic")
                            }
                        }
                        Spacer()
                    }
                    .buttonStyle(.bordered)
                }

                section("Diagnostics") {
                    HStack {
                        Button("Reveal Logs") { NSWorkspace.shared.open(AgentLogDir.url) }
                        Spacer()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
