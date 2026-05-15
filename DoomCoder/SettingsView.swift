import SwiftUI

struct SettingsView: View {
    @Bindable var sleepManager: SleepManager
    @Environment(\.openWindow) private var openWindow
    @State private var ntfyRegenerated = false
    @State private var axTrusted: Bool = AccessibilityPermission.isTrusted()

    // Timer fires every 3s while Settings is visible to pick up AX grant without
    // requiring the user to close and reopen. Also refreshed on foreground activation.
    private let axRefreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView(.vertical) {
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
                    LabeledContent("ntfy topic") {
                        Text(NtfyTopic.getOrCreate())
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Open Configure Agents…") {
                            NSApplication.shared.activate()
                            openWindow(id: "configureAgents")
                        }
                        Button("Reveal Logs") { NSWorkspace.shared.open(AgentLogDir.url) }
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
                    }
                    .buttonStyle(.bordered)
                }

                Section("Active Window Tracking") {
                    LabeledContent("Accessibility") {
                        HStack(spacing: 8) {
                            Image(systemName: axTrusted ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(axTrusted ? .green : .secondary)
                            Text(axTrusted ? "Granted" : "Not granted")
                                .foregroundStyle(axTrusted ? .primary : .secondary)
                        }
                    }
                    if !axTrusted {
                        Text("Grant Accessibility to let DoomCoder read the frontmost IDE window's working directory and highlight the active session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Open System Settings") {
                                AccessibilityPermission.openSystemSettings()
                            }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text("DoomCoder can detect which IDE window is frontmost and match it to active sessions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.vertical, 8)
            .frame(width: 480)
            .padding(.bottom, 8)
        }
        .frame(width: 480)
        .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 800) * 0.80)
        .onAppear { axTrusted = AccessibilityPermission.isTrusted() }
        .onReceive(axRefreshTimer) { _ in axTrusted = AccessibilityPermission.isTrusted() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AccessibilityPermission.isTrusted()
        }
    }
}
