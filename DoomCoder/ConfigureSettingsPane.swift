import SwiftUI
import AppKit
import DoomCoderCore

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
                LabeledContent("Open DoomCoder") {
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
                        HelpTip("After you move the mouse to wake the display in Screen Off mode, DoomCoder will put it back to sleep again after this many minutes of idle time.")
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
                        HelpTip("Some agents (Copilot CLI, Cursor, Windsurf) emit a permission hook before their own allowlist decides to auto-approve. DoomCoder waits this long for proof the tool actually ran before alerting you, eliminating auto-accept spam. Genuine blocks still notify after the window. Live status in the menu/Island is unaffected and always instant.")
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

            Section("Diagnostics") {
                Button("Reveal Logs") { NSWorkspace.shared.open(AgentLogDir.url) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
