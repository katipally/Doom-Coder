// SettingsView.swift — DoomCoder Companion
// Read-only settings: connection, notifications, about, test push, diagnostics.
// Sync is consolidated to a single "Force Sync Now" here (pull-to-refresh on the
// Agents list does the lightweight incremental refresh). Notifications can be
// enabled here as a fallback to the connect flow — they are always optional.

import SwiftUI
import CloudKit
import UserNotifications
import DoomCoderCore

struct SettingsView: View {
    @State private var macStore = MacStatusStore.shared
    @State private var sync = CompanionSyncEngine.shared
    @State private var testSent = false
    @State private var isForceSyncing = false
    @State private var forceSyncDone = false
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var showConnect = false
    @State private var showDisconnectConfirm = false
    @State private var aiKeyInput = ""
    @State private var keySettings = AIKeySettings.shared
    @State private var keyTestState: KeyTestState = .idle
    @State private var showClearDataConfirm = false

    private enum KeyTestState: Equatable {
        case idle, testing, ok, failed(String)
    }

    var body: some View {
        List {
            connectionSection
            aiSection
            manageDataSection
            notificationsSection
            aboutSection
            testSection
            diagnosticsSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await CompanionSyncEngine.shared.fetchChanges()
            await refreshNotifStatus()
        }
        .sheet(isPresented: $showConnect) {
            ConnectFlowView(onFinished: {})
        }
        .confirmationDialog(
            "Disconnect from this Mac?",
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                disconnectCurrentMac()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears the paired Mac and the cached agent data on this device. Your iCloud data and the DoomCoder Mac app are not affected. You can reconnect any time.")
        }
        .confirmationDialog(
            "Clear all tool data?",
            isPresented: $showClearDataConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete prompts, tasks & notes", role: .destructive) {
                PromptStore.shared.deleteAll()
                TaskStore.shared.deleteAll()
                NotesStore.shared.deleteAll()
                Haptics.success()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes your prompts, tasks, and notes on this device. Curated starters can be restored from the Prompts screen.")
        }
        .task { await refreshNotifStatus() }
    }

    // MARK: - AI enhance (BYO key)

    @ViewBuilder
    private var aiSection: some View {
        Section {
            Picker("Provider", selection: Binding(
                get: { keySettings.provider },
                set: { keySettings.provider = $0; keyTestState = .idle }
            )) {
                ForEach(AIProvider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }

            if keySettings.hasKeyForCurrentProvider {
                LabeledContent("API key") {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                Button {
                    Task { await testKey() }
                } label: {
                    HStack(spacing: 8) {
                        switch keyTestState {
                        case .testing: ProgressView().controlSize(.small)
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        default: Image(systemName: "checkmark.shield")
                        }
                        Text(testLabel)
                    }
                }
                .disabled(keyTestState == .testing)
                Button(role: .destructive) {
                    keySettings.clearKey(for: keySettings.provider)
                    keyTestState = .idle
                    Haptics.tap()
                } label: {
                    Label("Remove key", systemImage: "key.slash")
                }
            } else {
                SecureField(keySettings.provider.keyHint, text: $aiKeyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    keySettings.setKey(aiKeyInput, for: keySettings.provider)
                    aiKeyInput = ""
                    keyTestState = .idle
                    Haptics.success()
                } label: {
                    Label("Save key", systemImage: "key.fill")
                }
                .disabled(aiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Link(destination: keySettings.provider.consoleURL) {
                    Label("Where to find your API key", systemImage: "arrow.up.right.square")
                }
                .font(.subheadline)
            }
        } header: {
            Text("Smart Enhance")
        } footer: {
            if case let .failed(msg) = keyTestState {
                Text("Test failed: \(msg)")
                    .foregroundStyle(.red)
            } else {
                Text("Optional. Used only when you tap “Smart enhance” on a prompt. Your key stays in this device's Keychain; your prompt text is sent only to the provider you choose. Without a key, prompts are enhanced offline.")
            }
        }
    }

    private var testLabel: String {
        switch keyTestState {
        case .testing: return "Testing…"
        case .ok: return "Key works"
        case .failed: return "Test failed — tap to retry"
        default: return "Test key"
        }
    }

    private func testKey() async {
        guard let key = keySettings.key(for: keySettings.provider) else { return }
        keyTestState = .testing
        do {
            _ = try await AIEnhanceService.enhance(
                "say ok", provider: keySettings.provider, apiKey: key)
            keyTestState = .ok
            Haptics.success()
        } catch {
            keyTestState = .failed(error.localizedDescription)
            Haptics.warning()
        }
    }

    // MARK: - Manage data

    private var manageDataSection: some View {
        Section {
            Button(role: .destructive) {
                Haptics.tap()
                showClearDataConfirm = true
            } label: {
                Label("Clear prompts, tasks & notes", systemImage: "trash")
            }
        } header: {
            Text("Manage Data")
        } footer: {
            Text("Your tools data is stored only on this device. Nothing is uploaded.")
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            if let mac = macStore.primary {
                LabeledContent("Connected to") {
                    Text(mac.name).foregroundStyle(.secondary)
                }
                LabeledContent("Last seen") {
                    Text(mac.lastSeen, style: .relative)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Haptics.tap()
                    showConnect = true
                } label: {
                    Label("Switch Mac", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) {
                    Haptics.tap()
                    showDisconnectConfirm = true
                } label: {
                    Label("Disconnect", systemImage: "link.badge.minus")
                }
            } else {
                Button {
                    Haptics.tap()
                    showConnect = true
                } label: {
                    Label("Connect your Mac", systemImage: "link")
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            if macStore.primary != nil {
                Text("Disconnect if you want to switch iCloud accounts or pair a different Mac. Your data stays in iCloud and the Mac app keeps running.")
            } else {
                Text("Connect to the DoomCoder Mac app to see live agent status and control keep-awake remotely. The app is fully usable without a Mac.")
            }
        }
    }

    private func disconnectCurrentMac() {
        MacStatusStore.shared.clear()
        AgentListStore.shared.clear()
        NotificationLogStore.shared.clear()
        Haptics.success()
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            switch notifStatus {
            case .authorized, .provisional, .ephemeral:
                LabeledContent("Notifications") {
                    Label("Enabled", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            case .notDetermined:
                Button {
                    Task { await requestNotifications() }
                } label: {
                    Label("Enable Notifications", systemImage: "bell.badge")
                }
            default:
                Button {
                    openSystemSettings()
                } label: {
                    Label("Turn on in Settings", systemImage: "bell.slash")
                }
            }
        } footer: {
            Text("Optional. Used only to alert you when an agent on your Mac needs attention.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            }
            LabeledContent("Build") {
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            }
            LabeledContent("iCloud sync") {
                if let ts = sync.lastSyncAt {
                    Text(ts, style: .relative).foregroundStyle(.secondary)
                } else {
                    Text("Never").foregroundStyle(.secondary)
                }
            }

            if !macStore.byMacId.isEmpty {
                ForEach(Array(macStore.byMacId.values), id: \.macId) { mac in
                    LabeledContent(mac.name) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(mac.version).font(.caption)
                            Text(relativeTime(mac.lastSeen))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Test push

    private var testSection: some View {
        Section {
            Button {
                Task {
                    await sync.sendTestNotification()
                    testSent = true
                    try? await Task.sleep(for: .seconds(3))
                    testSent = false
                }
            } label: {
                Label(testSent ? "Sent ✓" : "Send Test Push", systemImage: "bell.badge")
            }
            .disabled(macStore.primary == nil || testSent)
        } footer: {
            Text("Sends a test notification through CloudKit. Requires a connected Mac.")
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Button {
                guard !isForceSyncing else { return }
                isForceSyncing = true
                forceSyncDone = false
                Task {
                    await sync.forceFetchAll()
                    isForceSyncing = false
                    forceSyncDone = true
                    Haptics.success()
                    try? await Task.sleep(for: .seconds(2))
                    forceSyncDone = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isForceSyncing {
                        ProgressView().controlSize(.small)
                    } else if forceSyncDone {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isForceSyncing ? "Syncing…" : forceSyncDone ? "Up to date" : "Force Sync Now")
                }
            }
            .disabled(isForceSyncing)

            NavigationLink {
                SyncDiagnosticsView()
            } label: {
                Label("Sync diagnostics", systemImage: "wave.3.right")
            }
        }
    }

    // MARK: - Helpers

    private func refreshNotifStatus() async {
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        await refreshNotifStatus()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h ago"
        } else {
            return "\(Int(interval / 86400))d ago"
        }
    }
}
