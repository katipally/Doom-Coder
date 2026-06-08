import SwiftUI
import AppKit
import DoomCodeCore

/// Settings pane embedded as the 4th tab of the Configure window. Replaces
/// the standalone `SettingsView` window scene. Every control here backs a
/// real, persistent preference — no stubs.
///
/// macOS 26 polish: migrated from `GroupBox`/VStack to a real
/// `Form { Section { … } }.formStyle(.grouped)` so the layout matches
/// the macOS 26 System Settings aesthetic (grouped, with the section
/// title in the bold uppercase label, and `LabeledContent` for
/// read-only values).
struct ConfigureSettingsPane: View {
    @Bindable var sleepManager: SleepManager
    @State private var autoRevertSeconds: Int = {
        UserDefaults.standard.object(forKey: "doomcoder.session.autoRevertSeconds") as? Int ?? 30
    }()
    @State private var redact: Bool = {
        UserDefaults.standard.object(forKey: "doomcoder.agents.redact") as? Bool ?? true
    }()
    @State private var deferTenths: Int = {
        let raw = UserDefaults.standard.object(forKey: "doomcoder.approval.deferSeconds") as? Double ?? 0.8
        return Int((min(max(raw, 0.5), 3.0) * 10).rounded())
    }()
    @State private var showDataPrivacy = false

    var body: some View {
        Form {
            Section {
                Text("Settings").font(.title2.bold()).textCase(nil)
            }

            Section("General") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { sleepManager.isLaunchAtLoginEnabled },
                    set: { _ in sleepManager.toggleLaunchAtLogin() }
                ))
                LabeledContent("Open Doom Coder") {
                    Text(GlobalHotkey.shared.current.descriptionForUI)
                        .font(.body.monospaced())
                }
                if GlobalHotkey.shared.conflictDetected {
                    Label("Another app may be using this shortcut. It won't fire until you change it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Works anywhere — no extra permission needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Screen Off") {
                Stepper(value: $sleepManager.screenOffRearmMinutes, in: 1...60) {
                    HStack {
                        Text("Re-sleep display after")
                        HelpTip("After you move the mouse to wake the display in Screen Off mode, Doom Coder will put it back to sleep again after this many minutes of idle time.")
                        Spacer()
                        Text("\(sleepManager.screenOffRearmMinutes) min idle")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Session Lifecycle") {
                Stepper(value: $autoRevertSeconds, in: 10...120, step: 5) {
                    HStack {
                        Text("Auto-revert completed sessions to idle after")
                        HelpTip("How long the 'completed' or 'failed' status badge stays on an agent row before it automatically reverts to 'idle'. Increase this if you miss notifications.")
                        Spacer()
                        Text("\(autoRevertSeconds)s")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: autoRevertSeconds) { _, new in
                    UserDefaults.standard.set(new, forKey: "doomcoder.session.autoRevertSeconds")
                }

                Stepper(value: $deferTenths, in: 5...30, step: 1) {
                    HStack {
                        Text("Approval debounce window")
                        HelpTip("Some agents (Copilot CLI, Cursor, Windsurf) emit a permission hook before their own allowlist decides to auto-approve. Doom Coder waits this long for proof the tool actually ran before alerting you, eliminating auto-accept spam. Genuine blocks still notify after the window. Live status in the menu/Island is unaffected and always instant.")
                        Spacer()
                        Text(String(format: "%.1fs", Double(deferTenths) / 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: deferTenths) { _, new in
                    UserDefaults.standard.set(Double(new) / 10, forKey: "doomcoder.approval.deferSeconds")
                }
            }

            Section("Privacy") {
                Toggle("Redact prompt text in local history", isOn: $redact)
                    .onChange(of: redact) { _, new in
                        UserDefaults.standard.set(new, forKey: "doomcoder.agents.redact")
                    }
                Text("Hides agent prompt and response content in the local event log and Logs view. Event type, timing, and status are still recorded. Enabled by default for privacy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AISettingsSection()

            Section("Data & Privacy") {
                Button {
                    showDataPrivacy = true
                } label: {
                    Label("Manage Data…", systemImage: "lock.shield")
                }
                Text("Clear individual data, or fully reset Doom Coder to a fresh-install state. Everything is stored on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Button("Reveal Logs") { NSWorkspace.shared.open(AgentLogDir.url) }
                Text("Opens Doom Coder's local log folder in Finder. Handy if something isn't working and you want to inspect or share the logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showDataPrivacy) {
            MacDataPrivacyView()
        }
    }
}

// MARK: - AI section (merged from the former standalone AI tab)

/// AI engine configuration rendered as a Form section so it sits inline
/// with the other Settings sections. Owns its own state + availability
/// probe. Uses the macOS 26 settings look — `Picker(.menu)`, `LabeledContent`
/// for the API-key saved label, monospaced text for key hints.
struct AISettingsSection: View {
    @State private var coordinator = AIEngineCoordinator.shared
    @State private var keyInput = ""
    @State private var keyTestState: KeyTestState = .idle
    @State private var appleReason: String?

    private enum KeyTestState: Equatable {
        case idle, testing, ok(Int), failed(String)
    }

    var body: some View {
        let _ = coordinator.revision   // re-render on key/model changes
        Section("AI") {
            Picker("Mode", selection: $coordinator.selection) {
                ForEach(AIEngineSelection.allCases) { Text($0.displayName).tag($0) }
            }
            .accessibilityLabel("AI mode")
            Text(coordinator.selection.detail)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if coordinator.selection == .appleOnDevice, let appleReason {
                Label(appleReason, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if coordinator.selection == .remoteKey {
                Picker("Provider", selection: Binding(
                    get: { coordinator.provider },
                    set: { newProvider in
                        coordinator.provider = newProvider
                        keyTestState = .idle
                        Task { await coordinator.loadModelsIfNeeded(for: newProvider) }
                    }
                )) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .accessibilityLabel("AI provider")

                if coordinator.hasKey(for: coordinator.provider) {
                    LabeledContent("API key") {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    }

                    let models = coordinator.discoveredModels[coordinator.provider] ?? []
                    if !models.isEmpty {
                        Picker("Model", selection: Binding(
                            get: {
                                let current = coordinator.selectedModel(for: coordinator.provider)
                                return models.contains(current) ? current : (models.first ?? current)
                            },
                            set: { coordinator.setSelectedModel($0, for: coordinator.provider) }
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
                            Text(coordinator.selectedModel(for: coordinator.provider)).foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button { Task { await testKey() } } label: {
                            Label("Test again", systemImage: "checkmark.shield")
                        }
                        .disabled(keyTestState == .testing)
                        Button(role: .destructive) {
                            coordinator.clearKey(for: coordinator.provider)
                            keyTestState = .idle
                        } label: {
                            Label("Remove key", systemImage: "key.slash")
                        }
                    }
                } else {
                    SecureField(coordinator.provider.keyHint, text: $keyInput)
                    Button {
                        let entered = keyInput
                        keyInput = ""
                        coordinator.setKey(entered, for: coordinator.provider)
                        Task { await testKey() }
                    } label: {
                        Label("Save & test key", systemImage: "key.fill")
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Link("Get a key", destination: coordinator.provider.consoleURL)
                    .font(.caption)
                statusLine
            }

            Text("Prompts and notes are stored only on this Mac. Nothing is synced. On-device stays fully local; with \"My API key\", your prompts are sent to the provider you choose over HTTPS.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            appleReason = (await coordinator.appleAvailability())?.message
            if coordinator.selection == .remoteKey {
                await coordinator.loadModelsIfNeeded(for: coordinator.provider)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch keyTestState {
        case .testing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Testing…") }
                .font(.caption).foregroundStyle(.secondary)
        case .ok(let n):
            Label("Key works — \(n) model\(n == 1 ? "" : "s") available", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private func testKey() async {
        keyTestState = .testing
        let result = await coordinator.testKey(for: coordinator.provider)
        switch result {
        case .success(let ids): keyTestState = .ok(ids.count)
        case .failure(let f):   keyTestState = .failed(f.message)
        }
    }
}

// MARK: - Data & Privacy (local data clearing + full reset)

/// Central, user-controlled data clearing for the Mac app. Granular methods wipe
/// one slice of on-device storage; `eraseEverything()` performs a full LOCAL
/// reset so the app behaves like a fresh install. Local-only — iCloud records
/// are never touched. The caller relaunches the app after a full erase.
@MainActor
enum MacDataManager {

    private static let aiKeyService = "com.doomcoder.app.companion.aikey"

    /// Local agent activity, notification and session history (events.sqlite).
    static func clearActivityHistory() {
        EventStore.shared.clearAll()
    }

    /// AI refine chats (local-only).
    static func clearPromptsAndChats() {
        MacConversationStore.shared.deleteAll()
    }

    /// Freeform notes (local-only).
    static func clearNotes() {
        MacNotesStore.shared.deleteAll()
    }

    /// API keys (Keychain) + AI provider/model/mode preferences.
    static func clearAIKeysAndSettings() {
        let ai = AIEngineCoordinator.shared
        for provider in AIProvider.allCases { ai.clearKey(for: provider) }
        Keychain.deleteAll(service: aiKeyService)
        let d = UserDefaults.standard
        d.removeObject(forKey: "tools.ai.selection")
        d.removeObject(forKey: "tools.ai.provider")
        for provider in AIProvider.allCases {
            d.removeObject(forKey: "tools.ai.model.\(provider.rawValue)")
        }
        ai.selection = .appleOnDevice
        ai.provider = .openai
    }

    /// Erases EVERYTHING — on-device data AND this Mac's CloudKit data — so the
    /// app behaves like a fresh install, then the UI relaunches. This Mac owns its
    /// iCloud zone, so the teardown deletes ALL published records + the share,
    /// which also empties every paired iPhone on its next sync.
    static func eraseEverything() async {
        // iCloud teardown FIRST, while the engine + account are still alive.
        await CloudKitPusher.shared.eraseCloudKitData()

        clearActivityHistory()
        clearPromptsAndChats()
        clearNotes()
        Keychain.deleteAll(service: aiKeyService)

        // All preferences: sleep config, CloudKit engine state + macId, AI prefs,
        // notification prefs, channels, migration flags — everything under the
        // app's UserDefaults domain (this is what survives a reinstall).
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }

        // Application Support: events.sqlite, cached icons, and the local-only
        // tool data (conversations/notes JSON).
        let fm = FileManager.default
        if let appSup = try? fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask, appropriateFor: nil, create: false) {
            for folder in ["DoomCoder", "DoomCoderTools"] {
                try? fm.removeItem(at: appSup.appendingPathComponent(folder, isDirectory: true))
            }
        }
    }

    /// Relaunches the app from scratch after a full erase.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Sheet listing each clearable data category plus a full "Erase All Data"
/// reset. Mirrors the iOS Data & Privacy screen.
struct MacDataPrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Category: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let systemImage: String
        let run: () -> Void
    }

    @State private var pending: Category?
    @State private var showEraseConfirm = false

    private var categories: [Category] {
        [
            Category(title: "Activity & notification history",
                     subtitle: "Local agent event, notification and session log.",
                     systemImage: "clock.arrow.circlepath",
                     run: { MacDataManager.clearActivityHistory() }),
            Category(title: "Prompts & AI chats",
                     subtitle: "Your saved refine conversations.",
                     systemImage: "text.bubble",
                     run: { MacDataManager.clearPromptsAndChats() }),
            Category(title: "Notes",
                     subtitle: "Every note and checklist on this Mac.",
                     systemImage: "note.text",
                     run: { MacDataManager.clearNotes() }),
            Category(title: "AI keys & settings",
                     subtitle: "Removes saved API keys from the Keychain and resets the AI mode.",
                     systemImage: "key",
                     run: { MacDataManager.clearAIKeysAndSettings() })
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Data & Privacy").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Form {
                Section {
                    ForEach(categories) { category in
                        Button {
                            pending = category
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: category.systemImage)
                                    .foregroundStyle(.tint)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.title).foregroundStyle(.primary)
                                    Text(category.subtitle)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Clear specific data")
                } footer: {
                    Text("Clear only what you choose. Everything here is stored on this Mac; your iCloud data and your iPhone are not affected.")
                }

                Section {
                    Button(role: .destructive) {
                        showEraseConfirm = true
                    } label: {
                        Label("Erase All Data", systemImage: "trash")
                    }
                } header: {
                    Text("Reset")
                } footer: {
                    Text("Erases everything on this Mac — history, prompts, notes, AI keys, preferences and sync state — so Doom Coder relaunches like a fresh install. This can’t be undone.")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 520)
        .confirmationDialog(
            pending.map { "Clear “\($0.title)”?" } ?? "",
            isPresented: Binding(get: { pending != nil },
                                 set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { category in
            Button("Clear", role: .destructive) {
                category.run()
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { _ in
            Text("This can’t be undone.")
        }
        .alert("Erase all data?", isPresented: $showEraseConfirm) {
            Button("Erase & Relaunch", role: .destructive) {
                Task {
                    await MacDataManager.eraseEverything()
                    MacDataManager.relaunch()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes all Doom Coder data from this Mac AND from iCloud — including the agents, notifications and status shown on every connected iPhone. The app will reset to a fresh-install state and relaunch. This can’t be undone.")
        }
    }
}
