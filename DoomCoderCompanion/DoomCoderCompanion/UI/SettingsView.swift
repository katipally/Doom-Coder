// SettingsView.swift — DoomCoder Companion
// Full-featured settings screen: phase toggles, channel toggles, sliders,
// master switch, privacy toggle, test notification, and About section.

import SwiftUI
import DoomCoderCore

struct SettingsView: View {

    @State private var store     = SettingsStore.shared
    @State private var macStore  = MacStatusStore.shared
    @State private var testSent  = false

    private var primaryMacId: String? { macStore.primary?.macId }

    var body: some View {
        NavigationStack {
            Form {
                masterSection
                channelsSection
                phaseSection
                timersSection
                privacySection
                testSection
                aboutSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Sections

    private var masterSection: some View {
        Section("Global") {
            Toggle("DoomCoder enabled", isOn: binding("masterEnabled", \.masterEnabled))
        }
    }

    private var channelsSection: some View {
        Section("Notification channels") {
            Toggle("macOS notifications", isOn: binding("channelMacEnabled", \.channelMacEnabled))
            Toggle("iOS notifications",   isOn: binding("channeliOSEnabled", \.channeliOSEnabled))
        }
    }

    private var phaseSection: some View {
        Section("Phase toggles") {
            Toggle("Session start",      isOn: binding("prefSessionStart",     \.prefSessionStart))
            Toggle("Session end",        isOn: binding("prefSessionEnd",       \.prefSessionEnd))
            Toggle("Error",              isOn: binding("prefError",            \.prefError))
            Toggle("Permission needed",  isOn: binding("prefPermissionNeeded", \.prefPermissionNeeded))
            Toggle("Agent response",     isOn: binding("prefAgentResponse",    \.prefAgentResponse))
            Toggle("Subagent start",     isOn: binding("prefSubagentStart",    \.prefSubagentStart))
            Toggle("Subagent end",       isOn: binding("prefSubagentEnd",      \.prefSubagentEnd))
            Toggle("Tool use",           isOn: binding("prefToolUse",          \.prefToolUse))
        }
    }

    private var timersSection: some View {
        Section("Timers") {
            // Retention days: discrete 1 / 7 / 30.
            VStack(alignment: .leading) {
                Text("Retention: \(store.current.retentionDays) day\(store.current.retentionDays == 1 ? "" : "s")")
                Slider(
                    value: Binding(
                        get: { Double(store.current.retentionDays) },
                        set: { v in store.update(field: "retentionDays") { $0.retentionDays = discreteRetention(v) } }
                    ),
                    in: 1...30,
                    step: 1
                )
            }

            VStack(alignment: .leading) {
                Text("Auto-revert after: \(store.current.autoRevertSec) s")
                Slider(
                    value: Binding(
                        get: { Double(store.current.autoRevertSec) },
                        set: { v in store.update(field: "autoRevertSec") { $0.autoRevertSec = Int(v) } }
                    ),
                    in: 10...120,
                    step: 5
                )
            }
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Toggle("Include payload snippets",
                   isOn: binding("includePayloadSnippets", \.includePayloadSnippets))
            Text("When enabled, truncated tool-output snippets are stored in iCloud and shown in notification bodies.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var testSection: some View {
        Section("Diagnostics") {
            Button(testSent ? "Sent ✓" : "Send test notification") {
                guard let macId = primaryMacId else { return }
                _ = CommandPublisher.shared.send(
                    verb: .sendTestNotification,
                    args: ["channel": "iOS"],
                    targetMacId: macId
                )
                testSent = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    testSent = false
                }
            }
            .disabled(primaryMacId == nil || testSent)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            }
            LabeledContent("Build") {
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            }

            if macStore.byMacId.isEmpty {
                Text("No paired Macs detected")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(macStore.byMacId.values), id: \.macId) { mac in
                    LabeledContent(mac.name) {
                        Text(mac.version)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Binding helpers

    /// Creates a two-way binding for a Bool settings field, touching the LWW timestamp on write.
    private func binding(
        _ field: String,
        _ keyPath: WritableKeyPath<SettingsRecord, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { store.current[keyPath: keyPath] },
            set: { newVal in store.update(field: field) { $0[keyPath: keyPath] = newVal } }
        )
    }

    private func discreteRetention(_ raw: Double) -> Int {
        // Map slider to nearest of 1, 7, 30.
        let options = [1, 7, 30]
        return options.min(by: { abs($0 - Int(raw)) < abs($1 - Int(raw)) }) ?? 7
    }
}
