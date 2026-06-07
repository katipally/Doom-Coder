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
    @State private var deviceNameInput = ""
    @FocusState private var deviceNameFocused: Bool

    private enum KeyTestState: Equatable {
        case idle, testing, ok(Int), failed(String)
    }

    var body: some View {
        List {
            connectionSection
            deviceSection
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
            deviceNameInput = AppGroupCache.customDeviceName
            await refreshNotifStatus()
            await probeApple()
            await ai.loadModelsIfNeeded(for: ai.provider)
        }
    }

    // MARK: - This Device

    private var deviceSection: some View {
        Section {
            TextField(DeviceModelName.current, text: $deviceNameInput)
                .focused($deviceNameFocused)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { commitDeviceName() }
                // Audit 2026-06: the placeholder is the model's default
                // name; add an explicit accessibility label so VoiceOver
                // announces "Device name" instead of the placeholder.
                .accessibilityLabel("Device name")
            if !deviceNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    deviceNameInput = ""
                    commitDeviceName()
                } label: {
                    Label("Use default name", systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text("This Device")
        } footer: {
            Text("The name your Mac shows for this device. Defaults to “\(DeviceModelName.current)”. iOS no longer shares your real device name with apps, so set a custom one here if you like.")
        }
        .onChange(of: deviceNameFocused) { _, focused in
            if !focused { commitDeviceName() }
        }
    }

    /// Persists the device name to the App Group and republishes presence so the
    /// Mac picks up the change promptly.
    private func commitDeviceName() {
        let trimmed = deviceNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != AppGroupCache.customDeviceName else { return }
        AppGroupCache.customDeviceName = trimmed
        deviceNameInput = trimmed
        Haptics.tap()
        Task { await CompanionSyncEngine.shared.publishCompanionStatus() }
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
        .accessibilityLabel("AI provider")

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
                .accessibilityLabel("AI model")
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
                // Audit 2026-06: the placeholder is a hint about the
                // expected key format ("sk-...") but VoiceOver reads it
                // as the field's label, which is wrong. Add a real
                // accessibility label.
                .accessibilityLabel("AI provider API key")
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
                    Label("Add Device", systemImage: "plus")
                }
                Button(role: .destructive) {
                    Haptics.tap()
                    showDisconnectConfirm = true
                } label: {
                    Label("Disconnect \(mac.name)", systemImage: "minus.circle")
                }
            } else {
                Button {
                    Haptics.tap()
                    showConnect = true
                } label: {
                    Label("Add Device", systemImage: "plus")
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
        if Date().timeIntervalSince(mac.lastSeen) >= 900 { return .red }
        return mac.sleepActive ? .green : Color.secondary.opacity(0.4)
    }

    private func connectionStatusLabel(_ mac: MacStatusRecord) -> String {
        if Date().timeIntervalSince(mac.lastSeen) >= 900 { return "Unreachable" }
        if mac.sleepActive {
            let n = mac.activeAgentCount ?? 0
            return n > 0 ? "Awake · \(n) agent\(n == 1 ? "" : "s")" : "Awake"
        }
        return (mac.masterEnabled ?? true) ? "Idle" : "Suspended"
    }

    private func disconnectCurrentMac() {
        guard let macId = macStore.primary?.macId else { return }
        Task {
            await CompanionSyncEngine.shared.leaveShare(forMacId: macId)
            // Disconnect only THIS Mac — keep any other connected Macs.
            MacStatusStore.shared.remove(macId: macId)
            AgentListStore.shared.clear(macId: macId)
            Haptics.success()
        }
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
                    Haptics.tap()
                    Task { await requestNotifications() }
                } label: {
                    Label("Enable Notifications", systemImage: "bell.badge")
                }
            default:
                Button {
                    Haptics.tap()
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

            // (Connected Macs are managed in the Dashboard switcher + Add Device.)

            // Audit 2026-06: provide a way to re-show the first-run
            // welcome sheet. The original flag was a one-way switch.
            Button {
                AppRouter.shared.showWelcome()
                Haptics.selection()
            } label: {
                Label("Show welcome again", systemImage: "hand.wave")
            }

            Link(destination: URL(string: "https://github.com/katipally/Doom-Coder/blob/main/docs/privacy.md")!) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
        }
    }

    // MARK: - Connection check

    @ViewBuilder
    private var testSection: some View {
        if macStore.primary != nil {
            Section {
                Button {
                    Task {
                        let cid = await sync.sendConnectionCheck()
                        testSent = (cid != nil)
                        try? await Task.sleep(for: .seconds(3))
                        testSent = false
                    }
                } label: {
                    Label(testSent ? "Sent ✓" : "Test Connection", systemImage: "bell.badge")
                }
                .disabled(testSent)
            } footer: {
                Text("Rings a test notification on your connected Mac to confirm the link.")
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

}
