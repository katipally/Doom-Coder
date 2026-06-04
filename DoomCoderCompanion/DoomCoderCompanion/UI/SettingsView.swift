// SettingsView.swift — DoomCoder Companion
// Read-only settings. Connection / pairing has been removed: data simply
// appears once the Mac publishes. Notifications, AI, and diagnostics remain.

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
            Link(destination: URL(string: "https://github.com/katipally/Doom-Coder/blob/main/docs/privacy.md")!) {
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
}
