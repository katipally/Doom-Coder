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
    @State private var ai = AIEngineCoordinator.shared
    @State private var keyTestState: KeyTestState = .idle
    @State private var appleStatus: AIFailure? = nil
    @State private var appleProbed = false
    @State private var showClearDataConfirm = false

    private enum KeyTestState: Equatable {
        case idle, testing, ok(Int), failed(String)
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
            Button("Delete prompts & notes", role: .destructive) {
                ConversationStore.shared.deleteAll()
                NotesStore.shared.deleteAll()
                Haptics.success()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes your saved prompt drafts and notes on this device. This can’t be undone.")
        }
        .task {
            await refreshNotifStatus()
            await probeApple()
            await ai.loadModelsIfNeeded(for: ai.provider)
        }
    }

    // MARK: - AI (on-device / BYO key)

    @ViewBuilder
    private var aiSection: some View {
        let _ = ai.revision   // subscribe so model/key changes re-render this section
        Section {
            Picker("Mode", selection: Binding(
                get: { ai.selection },
                set: { ai.selection = $0; keyTestState = .idle }
            )) {
                ForEach(AIEngineSelection.allCases) { sel in
                    Text(sel.displayName).tag(sel)
                }
            }
            .accessibilityLabel("AI mode")

            if ai.selection == .appleOnDevice {
                LabeledContent("On-device model") {
                    if !appleProbed {
                        ProgressView().controlSize(.small)
                    } else if appleStatus == nil {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
                if appleProbed, let status = appleStatus {
                    Text(status.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if ai.selection == .remoteKey {
                remoteKeyControls
            }
        } header: {
            Text("AI")
        } footer: {
            aiFooter
        }
    }

    @ViewBuilder
    private var remoteKeyControls: some View {
        Picker("Provider", selection: Binding(
            get: { ai.provider },
            set: { newProvider in
                ai.provider = newProvider
                keyTestState = .idle
                Task { await ai.loadModelsIfNeeded(for: newProvider) }
            }
        )) {
            ForEach(AIProvider.allCases) { p in
                Text(p.displayName).tag(p)
            }
        }

        if ai.hasKeyForCurrentProvider {
            LabeledContent("API key") {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout)
            }

            let models = ai.discoveredModels[ai.provider] ?? []
            if !models.isEmpty {
                Picker("Model", selection: Binding(
                    get: {
                        let current = ai.selectedModel(for: ai.provider)
                        return models.contains(current) ? current : (models.first ?? current)
                    },
                    set: { ai.setSelectedModel($0, for: ai.provider) }
                )) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            } else if keyTestState == .testing {
                LabeledContent("Model") {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }
            } else {
                LabeledContent("Model") {
                    Text(ai.selectedModel(for: ai.provider)).foregroundStyle(.secondary)
                }
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
                ai.clearKey(for: ai.provider)
                keyTestState = .idle
                Haptics.tap()
            } label: {
                Label("Remove key", systemImage: "key.slash")
            }
        } else {
            SecureField(ai.provider.keyHint, text: $aiKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                let entered = aiKeyInput
                aiKeyInput = ""
                ai.setKey(entered, for: ai.provider)
                Haptics.success()
                Task { await testKey() }   // auto-validate + fetch models on save
            } label: {
                Label("Save & test key", systemImage: "key.fill")
            }
            .disabled(aiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Link(destination: ai.provider.consoleURL) {
                Label("Where to find your API key", systemImage: "arrow.up.right.square")
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private var aiFooter: some View {
        if case let .failed(msg) = keyTestState {
            Text("Test failed: \(msg)").foregroundStyle(.red)
        } else if case let .ok(count) = keyTestState {
            Text("Key works — \(count) model\(count == 1 ? "" : "s") available.")
                .foregroundStyle(.green)
        } else {
            Text(ai.selection.detail + " Prompts and notes never leave your device unless you choose “My API key”, in which case only the text you enhance is sent to your chosen provider. Keys are stored in this device's Keychain.")
        }
    }

    private var testLabel: String {
        switch keyTestState {
        case .testing: return "Testing…"
        case .ok: return "Key works"
        case .failed: return "Test failed — tap to retry"
        default: return "Test key & load models"
        }
    }

    private func testKey() async {
        keyTestState = .testing
        let result = await ai.testKey(for: ai.provider)
        switch result {
        case .success(let models):
            keyTestState = .ok(models.count)
            Haptics.success()
        case .failure(let failure):
            keyTestState = .failed(failure.message)
            Haptics.warning()
        }
    }

    private func probeApple() async {
        appleStatus = await ai.appleAvailability()
        appleProbed = true
    }

    // MARK: - Manage data

    private var manageDataSection: some View {
        Section {
            Button(role: .destructive) {
                Haptics.tap()
                showClearDataConfirm = true
            } label: {
                Label("Clear prompts & notes", systemImage: "trash")
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
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionStatusColor(mac))
                            .frame(width: 8, height: 8)
                        Text(connectionStatusLabel(mac)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
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

    private func connectionStatusColor(_ mac: MacStatusRecord) -> Color {
        if Date().timeIntervalSince(mac.lastSeen) >= 600 { return .red }
        return mac.sleepActive ? .green : Color.secondary.opacity(0.4)
    }

    private func connectionStatusLabel(_ mac: MacStatusRecord) -> String {
        if Date().timeIntervalSince(mac.lastSeen) >= 600 { return "Unreachable" }
        if mac.sleepActive {
            let n = mac.activeAgentCount ?? 0
            return n > 0 ? "Awake · \(n) agent\(n == 1 ? "" : "s")" : "Awake"
        }
        return (mac.masterEnabled ?? true) ? "Idle" : "Suspended"
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

            Link(destination: URL(string: "https://github.com/katipally/Doom-Coder/blob/main/PRIVACY.md")!) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
        }
    }

    // MARK: - Test push

    @ViewBuilder
    private var testSection: some View {
        if macStore.primary != nil {
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
                .disabled(testSent)
            } footer: {
                Text("Sends a test notification through CloudKit to your connected Mac.")
            }
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
