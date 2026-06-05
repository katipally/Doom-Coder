import SwiftUI
import AppKit
import UserNotifications
import DoomCoderCore

/// Settings pane embedded as the 4th tab of the Configure window. Replaces
/// the standalone `SettingsView` window scene. Every control here backs a
/// real, persistent preference — no stubs.
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
    @State private var channelConfig = ChannelStore.load()
    @State private var testResult: (Bool, String)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.title.bold())
                    .padding(.top, 8)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Launch at Login", isOn: Binding(
                            get: { sleepManager.isLaunchAtLoginEnabled },
                            set: { _ in sleepManager.toggleLaunchAtLogin() }
                        ))
                        Divider()
                        HStack {
                            Text("Open DoomCoder")
                            Spacer()
                            Text(GlobalHotkey.shared.current.descriptionForUI)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if GlobalHotkey.shared.conflictDetected {
                            Label(
                                "Another app may be using this shortcut. It won't fire until you change it.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                            .font(.caption)
                        } else {
                            Text("Works anywhere — no extra permission needed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("General", systemImage: "gear")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Screen Off", systemImage: "moon.fill")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
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
                        Text("How long the badge shows \"completed\" or \"failed\" before reverting to \"idle\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

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
                        Text("Only affects the alert for auto-accepting agents — live status stays instant.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Session Lifecycle", systemImage: "clock.arrow.circlepath")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Toggle("Redact prompt text in local history", isOn: $redact)
                                .onChange(of: redact) { _, new in
                                    UserDefaults.standard.set(new, forKey: "doomcoder.agents.redact")
                                }
                            HelpTip("Hides agent prompt and response content in the local event log and Logs view. Event type, timing, and status are still recorded. Enabled by default for privacy.")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Privacy", systemImage: "hand.raised")
                }

                AISettingsSection()

                notificationsSection

                GroupBox {
                    Button("Reveal Logs") { NSWorkspace.shared.open(AgentLogDir.url) }
                        .buttonStyle(.bordered)
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { refreshPermStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermStatus()
        }
    }

    // MARK: - Notifications section

    private var notificationsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                permissionStatusGroup
                macOSNotificationGroup
                iPhoneIPadGroup
                testResultBanner
            }
        } label: {
            Label("Notifications", systemImage: "bell.badge")
        }
    }

    private var permissionStatusGroup: some View {
        GroupBox {
            HStack(spacing: 8) {
                let disp = NotificationDispatcher.shared
                switch disp.permissionStatus {
                case .authorized, .provisional, .ephemeral:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Notifications allowed").font(.callout)
                case .denied:
                    Image(systemName: "lock.circle.fill").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Enable notifications in System Settings").font(.callout)
                    Spacer()
                    Button {
                        disp.openSystemSettings()
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                    }
                    .controlSize(.small)
                case .notDetermined:
                    Image(systemName: "bell.badge.circle").foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    Text("Grant permission to receive notifications").font(.callout)
                    Spacer()
                    Button("Allow Notifications") {
                        disp.requestPermission { _ in refreshPermStatus() }
                    }
                    .controlSize(.small)
                @unknown default:
                    Text("Unknown").font(.callout)
                }
                Spacer()
            }
        } label: {
            Label("Permission Status", systemImage: "lock.shield")
        }
    }

    private var macOSNotificationGroup: some View {
        GroupBox {
            HStack {
                Toggle("macOS Notification", isOn: Binding(
                    get: { channelConfig.global.macNotification },
                    set: { v in
                        channelConfig.global.macNotification = v
                        ChannelStore.setGlobal(channelConfig.global)
                        if v { NotificationDispatcher.shared.requestPermission() }
                    }
                ))
                Spacer()
                Button("Test") {
                    ChannelTester.sendTest(channel: .macNotification) { ok, msg in
                        testResult = (ok, msg)
                    }
                }
            }
        } label: {
            Label("macOS", systemImage: "bell.fill")
        }
    }

    private var iPhoneIPadGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("iPhone / iPad", isOn: Binding(
                        get: { channelConfig.global.cloudkit },
                        set: { v in
                            channelConfig.global.cloudkit = v
                            ChannelStore.setGlobal(channelConfig.global)
                        }
                    ))
                    Spacer()
                    Button("Test") {
                        ChannelTester.sendTest(channel: .cloudKit) { ok, msg in
                            testResult = (ok, msg)
                        }
                    }
                }
                Text("Mirror notifications to the DoomCoder companion app on your iPhone or iPad via iCloud. Pair a device in the Connections tab — no manual setup needed once active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Image(systemName: CloudKitPusher.shared.isReady ? "checkmark.icloud.fill" : "icloud.slash")
                        .foregroundStyle(CloudKitPusher.shared.isReady ? .green : .secondary)
                        .accessibilityHidden(true)
                    Text(CloudKitPusher.shared.isReady
                         ? "Connected to iCloud as \(CloudKitPusher.shared.macName)"
                         : "Connecting to iCloud…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HelpTip("Must show green for iPhone mirroring to work. If it stays grey, make sure you're signed in to iCloud in System Settings and that iCloud Drive is enabled.")
                    Spacer()
                }
            }
        } label: {
            Label("iPhone / iPad", systemImage: "iphone.gen3")
        }
    }

    @ViewBuilder
    private var testResultBanner: some View {
        if let (ok, msg) = testResult {
            HStack {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? .green : .red)
                    .accessibilityHidden(true)
                Text(msg).font(.callout)
            }
            .padding(.top, 4)
        }
    }

    private func refreshPermStatus() {
        NotificationDispatcher.shared.refreshPermissionStatus()
    }
}

// MARK: - AI section (merged from the former standalone AI tab)

/// AI engine configuration rendered as a GroupBox so it sits inline with the
/// other Settings sections. Owns its own state + availability probe.
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
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
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
                    Divider()
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

                    if coordinator.hasKey(for: coordinator.provider) {
                        savedKeyControls
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
                    Link("Get a key", destination: coordinator.provider.consoleURL).font(.caption)
                    statusLine
                }

                Divider()
                Text("Prompts and notes are stored only on this Mac. Nothing is synced. On-device stays fully local; with “My API key”, your prompts are sent to the provider you choose over HTTPS.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("AI", systemImage: "sparkles")
        }
        .task {
            appleReason = (await coordinator.appleAvailability())?.message
            if coordinator.selection == .remoteKey {
                await coordinator.loadModelsIfNeeded(for: coordinator.provider)
            }
        }
    }

    @ViewBuilder
    private var savedKeyControls: some View {
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
