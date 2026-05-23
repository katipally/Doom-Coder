// SettingsView.swift — DoomCoder Companion (v4)
// 1:1 mirror of the Mac Configure → Settings pane so the user has a single
// mental model regardless of which device they're on. All controls back a
// real, sync'd SettingsRecord field (no stubs); each toggle/stepper shows a
// PendingBadge if the iOS→CloudKit→Mac round-trip exceeds 2 s.

import SwiftUI
import DoomCoderCore

struct SettingsView: View {

    @State private var store     = SettingsStore.shared
    @State private var macStore  = MacStatusStore.shared
    @State private var sync      = CompanionSyncEngine.shared
    @State private var syncStatus = SettingsSyncStatus.shared
    @State private var testSent  = false

    private var primaryMacId: String? { macStore.primary?.macId }

    var body: some View {
        NavigationStack {
            Form {
                generalSection
                screenOffSection
                sessionLifecycleSection
                notificationChannelsSection
                eventPreferencesSection
                privacySection
                primaryMacSection
                activitySection
                aboutSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if syncStatus.pending || syncStatus.lastErrorText != nil {
                        PendingBadge()
                    }
                }
            }
            .refreshable { await sync.fetchChanges() }
        }
    }

    // MARK: - Sections (matching the Mac Configure pane 1:1)

    private var generalSection: some View {
        Section {
            HStack {
                Toggle("DoomCoder enabled", isOn: boolBinding("masterEnabled", \.masterEnabled))
                if syncStatus.pending { PendingBadge() }
            }
            Picker("Mode", selection: stringBinding("mode", \.mode)) {
                Text("Screen On").tag("screenOn")
                Text("Screen Off").tag("screenOff")
            }
            Stepper(value: intBinding("sessionTimerHrs", \.sessionTimerHrs), in: 1...24) {
                HStack {
                    Text("Session timer")
                    Spacer()
                    Text("\(store.current.sessionTimerHrs) hr")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("General")
        } footer: {
            Text("Master switch pauses all DoomCoder activity. Mode selects how the Mac stays awake; the timer auto-disables after the chosen number of hours.")
        }
    }

    private var screenOffSection: some View {
        Section {
            Stepper(value: intBinding("screenOffRearmMin", \.screenOffRearmMin), in: 1...60) {
                HStack {
                    Text("Re-sleep display after")
                    Spacer()
                    Text("\(store.current.screenOffRearmMin) min idle")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Screen Off")
        } footer: {
            Text("In Screen Off mode, the display returns to sleep after this many minutes of no input.")
        }
    }

    private var sessionLifecycleSection: some View {
        Section {
            Stepper(value: intBinding("autoRevertSec", \.autoRevertSec), in: 10...120, step: 5) {
                HStack {
                    Text("Auto-revert after")
                    Spacer()
                    Text("\(store.current.autoRevertSec)s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Session Lifecycle")
        } footer: {
            Text("How long a completed or failed session badge shows before reverting to “idle”.")
        }
    }

    private var notificationChannelsSection: some View {
        Section {
            Toggle("macOS Notification", isOn: boolBinding("channelMacEnabled", \.channelMacEnabled))
            Toggle("iOS Companion",      isOn: boolBinding("channeliOSEnabled", \.channeliOSEnabled))
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
            Text("Notification Channels")
        } footer: {
            if !store.current.channeliOSEnabled {
                Text("iOS notifications are off — agent alerts will not deliver to this device.")
            } else {
                Text("Global channel defaults. Per-agent overrides live on the Mac Configure window.")
            }
        }
    }

    private var eventPreferencesSection: some View {
        Section {
            Toggle("Session start",        isOn: boolBinding("prefSessionStart", \.prefSessionStart))
            Toggle("Session end",          isOn: boolBinding("prefSessionEnd",   \.prefSessionEnd))
            Toggle("Errors",               isOn: boolBinding("prefError",        \.prefError))
            Toggle("Permission needed",    isOn: boolBinding("prefPermissionNeeded", \.prefPermissionNeeded))
            Toggle("Agent response",       isOn: boolBinding("prefAgentResponse",    \.prefAgentResponse))
            Toggle("Subagent start",       isOn: boolBinding("prefSubagentStart",    \.prefSubagentStart))
            Toggle("Subagent end",         isOn: boolBinding("prefSubagentEnd",      \.prefSubagentEnd))
            Toggle("Tool use",             isOn: boolBinding("prefToolUse",          \.prefToolUse))
        } header: {
            Text("Event Preferences")
        } footer: {
            Text("Which agent lifecycle events trigger a notification. Applies to whichever channels are enabled above.")
        }
    }

    private var privacySection: some View {
        Section {
            Toggle("Include payload snippets",
                   isOn: boolBinding("includePayloadSnippets", \.includePayloadSnippets))
            Stepper(value: intBinding("retentionDays", \.retentionDays), in: 1...90) {
                HStack {
                    Text("Local history retention")
                    Spacer()
                    Text("\(store.current.retentionDays) day\(store.current.retentionDays == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Payload snippets help debugging but may contain prompt text. History older than this is auto-purged on both devices.")
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

    private var activitySection: some View {
        Section("Activity") {
            NavigationLink {
                LogsView()
            } label: {
                Label("Notification history", systemImage: "bell.badge")
            }
            NavigationLink {
                SyncDiagnosticsView()
            } label: {
                Label("Sync diagnostics", systemImage: "wave.3.right")
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
            Text("Pull down on any tab to fetch the latest from iCloud.")
        }
    }

    // MARK: - Binding helpers

    private func boolBinding(_ field: String,
                             _ keyPath: WritableKeyPath<SettingsRecord, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.current[keyPath: keyPath] },
            set: { newVal in store.update(field: field) { $0[keyPath: keyPath] = newVal } }
        )
    }

    private func intBinding(_ field: String,
                            _ keyPath: WritableKeyPath<SettingsRecord, Int>) -> Binding<Int> {
        Binding(
            get: { store.current[keyPath: keyPath] },
            set: { newVal in store.update(field: field) { $0[keyPath: keyPath] = newVal } }
        )
    }

    private func stringBinding(_ field: String,
                               _ keyPath: WritableKeyPath<SettingsRecord, String>) -> Binding<String> {
        Binding(
            get: { store.current[keyPath: keyPath] },
            set: { newVal in store.update(field: field) { $0[keyPath: keyPath] = newVal } }
        )
    }
}
