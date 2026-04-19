import SwiftUI

// v2 configure window — NavigationSplitView with Agents + Channels tabs.
// Replaces the v1 wizard with accordion-style detail pane and per-agent
// actions (install, uninstall, reveal, open-in-IDE, demo, verify).
struct ConfigureAgentsViewV2: View {
    enum Tab: Hashable { case agents, channels }
    @State private var tab: Tab = .agents
    @State private var selected: TrackedAgent? = .claude
    @State private var detections: [TrackedAgent: AgentDetection] = [:]
    @State private var statusMessage: String = ""
    @State private var verifyWaiting = false
    @State private var verifyResult: String? = nil
    @State private var showMigrationAlert = false
    @State private var migrationAgents: [TrackedAgent] = []
    // Copilot CLI folders
    @State private var cliFolders: [URL] = CopilotCLIFolderManager.folders
    @State private var installedCache: [TrackedAgent: Bool] = [:]
    // Channel store
    @State private var channelConfig = ChannelStore.load()
    // Channel test results
    @State private var testResult: (Bool, String)? = nil

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            switch tab {
            case .agents:
                if let agent = selected {
                    agentDetail(agent)
                } else {
                    ContentUnavailableView("Select an agent", systemImage: "sidebar.left")
                }
            case .channels:
                channelsDetail
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            await detectAllAsync()
            checkMigration()
        }
        .alert("Update Hook Configs", isPresented: $showMigrationAlert) {
            Button("Update All") {
                MigrationManager.migrate(agents: migrationAgents)
                detectAll()
                statusMessage = "Migration complete — hooks updated to v2 format."
            }
            Button("Skip", role: .cancel) { MigrationManager.markDone() }
        } message: {
            Text("DoomCoder found outdated hook configurations for: \(migrationAgents.map(\.displayName).joined(separator: ", ")). Update to v2 format?")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section("Agents") {
                ForEach(TrackedAgent.allCases, id: \.self) { agent in
                    Button {
                        tab = .agents
                        selected = agent
                    } label: {
                        agentRow(agent)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        (tab == .agents && selected == agent)
                        ? Color.accentColor.opacity(0.15) : Color.clear
                    )
                }
            }

            Section {
                Button {
                    tab = .channels
                    selected = nil
                } label: {
                    Label("Channels", systemImage: "bell.badge")
                }
                .buttonStyle(.plain)
                .listRowBackground(tab == .channels ? Color.accentColor.opacity(0.15) : Color.clear)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Configure")
    }

    @ViewBuilder
    private func agentRow(_ agent: TrackedAgent) -> some View {
        let d = detections[agent]
        let isInst = installedCache[agent] ?? false
        HStack(spacing: 8) {
            Image(nsImage: AgentIconProvider.icon(for: agent, size: 24))
                .resizable()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName).font(.body)
                Text(d?.installed == true ? (d?.version ?? "installed") : "not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isInst {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Agent detail

    @ViewBuilder
    private func agentDetail(_ agent: TrackedAgent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(nsImage: AgentIconProvider.icon(for: agent, size: 48))
                        .resizable()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.displayName).font(.title.bold())
                        Text(subtitle(agent)).foregroundStyle(.secondary)
                    }
                }

                // Detection
                GroupBox {
                    HStack {
                        let d = detections[agent]
                        if d?.installed == true {
                            Label("Detected \(d?.version ?? "")", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            if let detail = d?.details {
                                Text("(\(detail))").font(.caption).foregroundStyle(.tertiary)
                            }
                        } else {
                            Label("Not detected", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            if agent == .copilotCLI {
                                Text("Install anyway — detection is optional")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button("Re-scan") { detectAll() }
                    }
                } label: {
                    Label("Detection", systemImage: "magnifyingglass")
                }

                // Copilot CLI: folder management
                if agent == .copilotCLI {
                    copilotCLIFoldersSection
                }

                // Install / Uninstall
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Config: \(configPathHint(agent))")
                            .font(.callout).foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            if agent == .copilotCLI {
                                // handled per-folder above
                            } else {
                                let isInst = installedCache[agent] ?? false
                                Button(isInst ? "Reinstall" : "Install") {
                                    let r = AgentInstallerV2.install(agent)
                                    statusMessage = resultMessage(r, verb: "Install")
                                    Task { await detectAllAsync() }
                                }
                                if isInst {
                                    Button("Uninstall", role: .destructive) {
                                        let r = AgentInstallerV2.uninstall(agent)
                                        statusMessage = resultMessage(r, verb: "Uninstall")
                                        Task { await detectAllAsync() }
                                    }
                                }
                            }

                            Spacer()

                            Button {
                                DeepLink.revealInFinder(agent)
                            } label: {
                                Label("Reveal file", systemImage: "folder")
                            }

                            Button {
                                DeepLink.openInIDE(agent)
                            } label: {
                                Label("Open in IDE", systemImage: "arrow.up.forward.app")
                            }
                        }
                    }
                } label: {
                    Label("Hooks", systemImage: "link")
                }

                // Verify
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Button("Ping helper") { pingHelper() }

                            Button(verifyWaiting ? "Waiting…" : "Run demo session") {
                                startDemoSession(agent: agent)
                            }
                            .disabled(verifyWaiting)

                            Spacer()
                        }
                        if let r = verifyResult {
                            Text(r).font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("Ping checks dc-hook can reach DoomCoder. Demo runs a synthetic 30s lifecycle.")
                                .font(.callout).foregroundStyle(.tertiary)
                        }
                    }
                } label: {
                    Label("Verify", systemImage: "checkmark.shield")
                }

                // Channel overrides
                GroupBox {
                    let hasOverride = ChannelStore.hasOverride(for: agent)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Use custom channels (override global)", isOn: Binding(
                            get: { hasOverride },
                            set: { on in
                                if on {
                                    ChannelStore.setPerAgent(agent, config: channelConfig.global)
                                } else {
                                    ChannelStore.clearOverride(for: agent)
                                }
                                channelConfig = ChannelStore.load()
                            }
                        ))

                        if hasOverride {
                            let override = channelConfig.perAgent[agent.rawValue] ?? channelConfig.global
                            Toggle("macOS Notification", isOn: Binding(
                                get: { override.macNotification },
                                set: { v in
                                    var c = override; c.macNotification = v
                                    ChannelStore.setPerAgent(agent, config: c)
                                    channelConfig = ChannelStore.load()
                                    if v { NotificationDispatcher.shared.requestPermission() }
                                }
                            ))
                            Toggle("ntfy", isOn: Binding(
                                get: { override.ntfy },
                                set: { v in
                                    var c = override; c.ntfy = v
                                    ChannelStore.setPerAgent(agent, config: c)
                                    channelConfig = ChannelStore.load()
                                }
                            ))
                        } else {
                            Text("Using global channel settings.")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                } label: {
                    Label("Channel Overrides", systemImage: "bell.badge")
                }

                // Status
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Copilot CLI folders

    private var copilotCLIFoldersSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(cliFolders, id: \.path) { folder in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.secondary)
                        Text(folder.path)
                            .lineLimit(1).truncationMode(.middle)
                            .font(.callout)
                        Spacer()
                        let isInst = AgentInstallerV2.isInstalledCLI(folder: folder)
                        if isInst {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                        Button(isInst ? "Reinstall" : "Install") {
                            _ = CopilotCLIFolderManager.installHooks(in: folder)
                            cliFolders = CopilotCLIFolderManager.folders
                        }
                        .controlSize(.small)
                        Button("Remove") {
                            _ = CopilotCLIFolderManager.uninstallHooks(from: folder)
                            cliFolders = CopilotCLIFolderManager.folders
                        }
                        .controlSize(.small)
                    }
                }

                HStack {
                    Button("Add Folder…") {
                        let p = NSOpenPanel()
                        p.canChooseFiles = false
                        p.canChooseDirectories = true
                        p.allowsMultipleSelection = false
                        if p.runModal() == .OK, let url = p.url {
                            CopilotCLIFolderManager.addFolder(url)
                            cliFolders = CopilotCLIFolderManager.folders
                        }
                    }
                    Spacer()
                    Text("\(cliFolders.count) folder\(cliFolders.count == 1 ? "" : "s") registered")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        } label: {
            Label("Project Folders", systemImage: "folder.badge.gearshape")
        }
    }

    // MARK: - Channels tab

    private var channelsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Notification Channels").font(.title.bold())
                Text("Global defaults applied to all agents unless overridden.")
                    .foregroundStyle(.secondary)

                // macOS Notification
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

                // ntfy
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("ntfy", isOn: Binding(
                                get: { channelConfig.global.ntfy },
                                set: { v in
                                    channelConfig.global.ntfy = v
                                    ChannelStore.setGlobal(channelConfig.global)
                                }
                            ))
                            Spacer()
                            Button("Test") {
                                ChannelTester.sendTest(channel: .ntfy) { ok, msg in
                                    testResult = (ok, msg)
                                }
                            }
                        }

                        HStack {
                            Text("Topic:")
                                .font(.callout).foregroundStyle(.secondary)
                            Text(NtfyTopic.getOrCreate())
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy") {
                                if let url = NtfyTopic.shareURL {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                }
                            }
                            Button("Regenerate") { _ = NtfyTopic.regenerate() }
                        }

                        HStack {
                            Text("Server:")
                                .font(.callout).foregroundStyle(.secondary)
                            Text(NtfyTopic.server ?? "https://ntfy.sh")
                                .font(.callout)
                        }
                    }
                } label: {
                    Label("ntfy", systemImage: "paperplane.fill")
                }

                // Test result
                if let (ok, msg) = testResult {
                    HStack {
                        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(ok ? .green : .red)
                        Text(msg).font(.callout)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Actions

    private func detectAll() {
        // Fire and forget — result updates state on main actor when done.
        Task { await detectAllAsync() }
    }

    private func detectAllAsync() async {
        let results = await Task.detached(priority: .userInitiated) { () -> ([AgentDetection], [TrackedAgent: Bool]) in
            let dets = AgentDetector.detectAll()
            var inst: [TrackedAgent: Bool] = [:]
            for a in TrackedAgent.allCases {
                if a == .copilotCLI {
                    inst[a] = !CopilotCLIFolderManager.installedFolders().isEmpty
                } else {
                    inst[a] = AgentInstallerV2.isInstalled(a)
                }
            }
            return (dets, inst)
        }.value
        var d: [TrackedAgent: AgentDetection] = [:]
        for det in results.0 { d[det.agent] = det }
        detections = d
        installedCache = results.1
        cliFolders = CopilotCLIFolderManager.folders
    }

    private func checkMigration() {
        Task.detached(priority: .utility) {
            let affected = MigrationManager.checkNeeded()
            await MainActor.run {
                if !affected.isEmpty {
                    migrationAgents = affected
                    showMigrationAlert = true
                }
            }
        }
    }

    private func pingHelper() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: AgentInstallerV2.helperBinaryPath())
        proc.arguments = ["--ping"]
        do {
            try proc.run(); proc.waitUntilExit()
            verifyResult = proc.terminationStatus == 0
                ? "✅ Ping passed — dc-hook can reach DoomCoder."
                : "❌ Ping failed — helper exited \(proc.terminationStatus)."
        } catch {
            verifyResult = "❌ Ping failed — \(error.localizedDescription)"
        }
    }

    private func startDemoSession(agent: TrackedAgent) {
        verifyWaiting = true
        verifyResult = nil
        // Fire demo via dc-hook --replay-demo <agent>
        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: AgentInstallerV2.helperBinaryPath())
            proc.arguments = ["--replay-demo", agent.rawValue]
            try? proc.run()
            proc.waitUntilExit()
            await MainActor.run {
                verifyResult = proc.terminationStatus == 0
                    ? "✅ Demo complete — check Track Agents and notifications."
                    : "❌ Demo failed — exit \(proc.terminationStatus)."
                verifyWaiting = false
            }
        }
    }

    // MARK: - Helpers

    private func subtitle(_ agent: TrackedAgent) -> String {
        switch agent {
        case .claude:     return "Hooks in ~/.claude/settings.json (nested matcher format)"
        case .cursor:     return "Hooks in ~/.cursor/hooks.json (version: 1, command only)"
        case .vscode:     return "VS Code reads ~/.claude/settings.json natively"
        case .copilotCLI: return "Per-project .github/hooks/doomcoder.json (bash/cwd/timeoutSec)"
        }
    }

    private func configPathHint(_ agent: TrackedAgent) -> String {
        switch agent {
        case .claude:     return "~/.claude/settings.json"
        case .cursor:     return "~/.cursor/hooks.json"
        case .vscode:     return "~/.claude/settings.json"
        case .copilotCLI: return ".github/hooks/doomcoder.json"
        }
    }

    private func resultMessage(_ r: Result<Void, Error>, verb: String) -> String {
        switch r {
        case .success: return "\(verb) successful."
        case .failure(let e): return "\(verb) failed: \(e.localizedDescription)"
        }
    }
}
