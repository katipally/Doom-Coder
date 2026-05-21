// SettingsView.swift — DoomCoder Companion
// Full-featured settings screen: phase toggles, channel toggles, sliders,
// master switch, privacy toggle, test notification, and About section.

import SwiftUI
import DoomCoderCore

struct SettingsView: View {

    @State private var store     = SettingsStore.shared
    @State private var macStore  = MacStatusStore.shared
    @State private var sync      = CompanionSyncEngine.shared
    @State private var testSent  = false

    private var primaryMacId: String? { macStore.primary?.macId }

    var body: some View {
        NavigationStack {
            Form {
                masterSection
                channelsSection
                primaryMacSection
                historySection
                aboutSection
            }
            .navigationTitle("Settings")
            .refreshable { await sync.fetchChanges() }
        }
    }

    // MARK: - Sections

    private var masterSection: some View {
        Section {
            Toggle("DoomCoder enabled", isOn: binding("masterEnabled", \.masterEnabled))
        } footer: {
            Text("Pauses all DoomCoder activity on your Mac. Sleep prevention, hook tracking, and notifications stop until you re-enable.")
        }
    }

    private var channelsSection: some View {
        Section {
            Toggle("iOS notifications", isOn: binding("channeliOSEnabled", \.channeliOSEnabled))
            Button {
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
            } label: {
                Label(testSent ? "Sent ✓" : "Send test notification", systemImage: "bell.badge")
            }
            .disabled(primaryMacId == nil || testSent || !store.current.channeliOSEnabled)
        } header: {
            Text("Notifications")
        } footer: {
            if !store.current.channeliOSEnabled {
                Text("iOS notifications are off — agent toggles will not deliver alerts to this device.")
            }
        }
    }

    @ViewBuilder
    private var primaryMacSection: some View {
        if macStore.byMacId.count > 1 {
            Section("Primary Mac") {
                Picker("Primary Mac", selection: Binding(
                    get: { macStore.primaryMacIdOverride ?? macStore.primary?.macId ?? "" },
                    set: { macStore.setPrimary($0.isEmpty ? nil : $0) }
                )) {
                    ForEach(Array(macStore.byMacId.values.sorted(by: { $0.name < $1.name })), id: \.macId) { mac in
                        Text(mac.name).tag(mac.macId)
                    }
                }
                .pickerStyle(.menu)
                Text("Notifications, Settings, and remote commands target this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var historySection: some View {
        Section("Activity") {
            NavigationLink {
                LogsView()
            } label: {
                Label("Notification history", systemImage: "bell.badge")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            }
            LabeledContent("Build") {
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            }
            LabeledContent("Last sync") {
                if let ts = sync.lastSyncAt {
                    Text(ts, style: .relative).foregroundStyle(.secondary)
                } else {
                    Text("Never").foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await sync.fetchChanges() }
            } label: {
                Label("Sync now", systemImage: "arrow.clockwise")
            }

            if macStore.byMacId.isEmpty {
                Text("No paired Macs detected")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(macStore.byMacId.values), id: \.macId) { mac in
                    LabeledContent(mac.name) {
                        Text(mac.version).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("About")
        } footer: {
            Text("Pull down on any tab to fetch the latest from iCloud. Phase, retention, and payload preferences live on your Mac.")
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
}
