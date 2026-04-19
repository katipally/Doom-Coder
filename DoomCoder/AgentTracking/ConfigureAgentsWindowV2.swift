import SwiftUI
import CoreImage

// v2 configure window — NavigationSplitView with Agents + Channels + Logs tabs.
// Replaces the v1 wizard with accordion-style detail pane and per-agent
// actions (install, uninstall, reveal, open-in-IDE, demo, verify).
struct ConfigureAgentsViewV2: View {
    enum Tab: Hashable { case agents, channels, logs }
    @State private var tab: Tab = .agents
    @State private var selected: TrackedAgent? = .claude
    @State private var detections: [TrackedAgent: AgentDetection] = [:]
    @State private var statusMessage: String = ""
    @State private var verifyWaiting = false
    @State private var verifyResult: String? = nil
    @State private var realWatching = false
    @State private var showMigrationAlert = false
    @State private var migrationAgents: [TrackedAgent] = []
    // Copilot CLI folders
    @State private var cliFolders: [URL] = CopilotCLIFolderManager.folders
    @State private var installedCache: [TrackedAgent: Bool] = [:]
    // Channel store
    @State private var channelConfig = ChannelStore.load()
    // Channel test results
    @State private var testResult: (Bool, String)? = nil
    // Hook validation warnings
    @State private var hookWarnings: [TrackedAgent: String] = [:]
    // Permission status
    @State private var permStatus: String = "…"
    // Periodic health refresh
    private let healthTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

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
            case .logs:
                LogsView()
            }
        }
        .frame(minWidth: 820, minHeight: 580)
        .task {
            await detectAllAsync()
            checkMigration()
            refreshPermStatus()
            validateAllHooks()
        }
        .onReceive(healthTimer) { _ in
            validateAllHooks()
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

                Button {
                    tab = .logs
                    selected = nil
                } label: {
                    Label("Logs", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.plain)
                .listRowBackground(tab == .logs ? Color.accentColor.opacity(0.15) : Color.clear)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Configure")
    }

    @ViewBuilder
    private func agentRow(_ agent: TrackedAgent) -> some View {
        let d = detections[agent]
        let isInst = installedCache[agent] ?? false
        let eventCount = EventStore.shared.recentCount(agent: agent.rawValue, seconds: 3600)
        let hasWarning = hookWarnings[agent] != nil
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
            if hasWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            } else if isInst {
                // Health dot: green if events in last hour, grey otherwise
                Circle()
                    .fill(eventCount > 0 ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            } else if d?.installed == true {
                // Agent detected but hooks not installed: nudge
                Text("Set up →")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
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

                // Health Monitoring
                if installedCache[agent] == true {
                    GroupBox {
                        let eventCount = EventStore.shared.recentCount(agent: agent.rawValue, seconds: 3600)
                        let todayCount = EventStore.shared.recentCount(agent: agent.rawValue, seconds: 86400)
                        let lastEv = EventStore.shared.lastEvent(agent: agent.rawValue)
                        HStack(spacing: 16) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(eventCount > 0 ? Color.green : Color.secondary.opacity(0.3))
                                    .frame(width: 10, height: 10)
                                Text(eventCount > 0 ? "Active" : "Quiet")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(eventCount > 0 ? .primary : .secondary)
                            }
                            Text("\(todayCount) today")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let last = lastEv {
                                Text("Last: \(timeAgo(Date(timeIntervalSince1970: last.ts)))")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                    } label: {
                        Label("Health", systemImage: "heart.text.square")
                    }
                }

                // Hook Validation Warning
                if let warning = hookWarnings[agent] {
                    GroupBox {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(warning)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Repair") {
                                let r = AgentInstallerV2.install(agent)
                                statusMessage = resultMessage(r, verb: "Repair")
                                Task { await detectAllAsync(); validateAllHooks() }
                            }
                        }
                    } label: {
                        Label("Hook Warning", systemImage: "exclamationmark.shield")
                    }
                }

                // Prerequisites (dynamic checks)
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(dynamicPrereqs(for: agent), id: \.label) { prereq in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: prereq.met ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundStyle(prereq.met ? .green : .red)
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(prereq.label).font(.callout)
                                    if !prereq.met, let fix = prereq.fix {
                                        Text(fix)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Recheck") { detectAll() }
                                .controlSize(.small)
                        }
                    }
                } label: {
                    Label("Prerequisites", systemImage: "list.bullet.clipboard")
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
                            VStack(alignment: .leading, spacing: 2) {
                                Button("Test Helper") { pingHelper() }
                                Text("Checks dc-hook binary").font(.caption2).foregroundStyle(.tertiary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Button(verifyWaiting ? "Running…" : "Run Demo") {
                                    startDemoSession(agent: agent)
                                }
                                .disabled(verifyWaiting)
                                Text("Simulates agent session").font(.caption2).foregroundStyle(.tertiary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Button(realWatching ? "Watching…" : "Watch Live") {
                                    watchRealSession(agent: agent)
                                }
                                .disabled(realWatching)
                                Text("Waits for real hook (2 min)").font(.caption2).foregroundStyle(.tertiary)
                            }

                            Spacer()
                        }
                        if let r = verifyResult {
                            Text(r).font(.callout).foregroundStyle(.secondary)
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

                // Permission Status
                GroupBox {
                    HStack(spacing: 8) {
                        let disp = NotificationDispatcher.shared
                        switch disp.permissionStatus {
                        case .authorized, .provisional, .ephemeral:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Notifications allowed").font(.callout)
                        case .denied:
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text("Notifications denied").font(.callout)
                            Spacer()
                            Button("Open System Settings →") {
                                disp.openSystemSettings()
                            }
                        case .notDetermined:
                            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                            Text("Not asked yet").font(.callout)
                            Spacer()
                            Button("Request Permission") {
                                disp.requestPermission { _ in refreshPermStatus() }
                            }
                        @unknown default:
                            Text("Unknown").font(.callout)
                        }
                        Spacer()
                    }
                } label: {
                    Label("Permission Status", systemImage: "lock.shield")
                }

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
                            Button("Copy Topic") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(NtfyTopic.getOrCreate(), forType: .string)
                            }
                            Button("Regenerate") { _ = NtfyTopic.regenerate() }
                        }

                        HStack {
                            Text("Server:")
                                .font(.callout).foregroundStyle(.secondary)
                            Text(NtfyTopic.server ?? "https://ntfy.sh")
                                .font(.callout)
                            Spacer()
                        }

                        HStack {
                            if let url = NtfyTopic.shareURL {
                                Text("Subscribe URL:")
                                    .font(.callout).foregroundStyle(.secondary)
                                Text(url.absoluteString)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                                Button("Copy Subscribe URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                }
                            }
                        }

                        // QR Code
                        if let url = NtfyTopic.shareURL {
                            HStack {
                                Spacer()
                                qrCodeImage(for: url.absoluteString)
                                    .resizable()
                                    .interpolation(.none)
                                    .frame(width: 120, height: 120)
                                Spacer()
                            }
                            Text("Scan to subscribe on your phone")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
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

    private func watchRealSession(agent: TrackedAgent) {
        realWatching = true
        verifyResult = "⏱ Open \(agent.displayName) and trigger one real prompt within 120s…"
        let baseline = Date().timeIntervalSince1970
        let agentKey = agent.rawValue
        Task.detached {
            let deadline = Date().addingTimeInterval(120)
            var matched: EventStore.Row? = nil
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let rows = await EventStore.shared.recent(limit: 50)
                if let hit = rows.first(where: { $0.agent == agentKey && $0.ts >= baseline && !$0.event.hasPrefix("demo-") && $0.event != "ping" }) {
                    matched = hit
                    break
                }
            }
            await MainActor.run {
                if let hit = matched {
                    verifyResult = "✅ Real \(agent.displayName) event received: \(hit.event)"
                } else {
                    verifyResult = "❌ No real \(agent.displayName) event in 120s. Re-run Gate A/B if Ping/Demo also fail."
                }
                realWatching = false
            }
        }
    }

    // MARK: - Helpers

    private struct Prereq: Identifiable {
        let label: String
        let met: Bool
        let fix: String?
        var id: String { label }
    }

    private func dynamicPrereqs(for agent: TrackedAgent) -> [Prereq] {
        let dcHookOK = FileManager.default.isExecutableFile(atPath: AgentInstallerV2.helperBinaryPath())
        var list: [Prereq] = []
        list.append(Prereq(
            label: "dc-hook binary ready",
            met: dcHookOK,
            fix: dcHookOK ? nil : "Binary not found — try reinstalling DoomCoder"
        ))
        switch agent {
        case .claude:
            let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
            let file = dir.appending(path: "settings.json")
            list.append(Prereq(label: "~/.claude/ exists", met: FileManager.default.fileExists(atPath: dir.path), fix: "Run `claude` once to initialize"))
            list.append(Prereq(label: "settings.json writable", met: FileManager.default.isWritableFile(atPath: file.path), fix: "Check permissions on ~/.claude/settings.json"))
        case .cursor:
            let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cursor")
            list.append(Prereq(label: "~/.cursor/ exists", met: FileManager.default.fileExists(atPath: dir.path), fix: "Install Cursor first"))
            list.append(Prereq(label: "Cursor 0.45+ with Hooks enabled", met: detections[.cursor]?.installed == true, fix: "Enable Hooks in Settings → Beta"))
        case .vscode:
            let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
            list.append(Prereq(label: "~/.claude/ exists (shared config)", met: FileManager.default.fileExists(atPath: dir.path), fix: "Run `claude` once or create ~/.claude/ manually"))
            list.append(Prereq(label: "VS Code + Copilot Chat extension", met: true, fix: nil))
        case .copilotCLI:
            list.append(Prereq(label: "GitHub Copilot CLI installed", met: detections[.copilotCLI]?.installed == true, fix: "Install via npm, brew, or gh extension"))
            list.append(Prereq(label: "At least 1 project folder configured", met: !cliFolders.isEmpty, fix: "Click 'Add folder' below"))
        }
        return list
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s/60)m ago" }
        if s < 86400 { return "\(s/3600)h ago" }
        return "\(s/86400)d ago"
    }

    private func refreshPermStatus() {
        NotificationDispatcher.shared.refreshPermissionStatus()
    }

    private func validateAllHooks() {
        var warnings: [TrackedAgent: String] = [:]
        for agent in TrackedAgent.allCases {
            guard installedCache[agent] == true else { continue }
            let result = AgentInstallerV2.verifyInstalled(agent)
            switch result {
            case .failure:
                warnings[agent] = "Hook config may have been modified externally"
            default:
                break
            }
        }
        hookWarnings = warnings
    }

    private func qrCodeImage(for string: String) -> Image {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return Image(systemName: "qrcode")
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else {
            return Image(systemName: "qrcode")
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let ns = NSImage(size: rep.size)
        ns.addRepresentation(rep)
        return Image(nsImage: ns)
    }

    private func prerequisites(for agent: TrackedAgent) -> [String] {
        switch agent {
        case .claude:
            return [
                "Claude Code CLI installed (any version that supports hooks).",
                "Folder ~/.claude/ writable.",
                "Run `claude` once so the settings file is initialised."
            ]
        case .cursor:
            return [
                "Cursor 0.45 or later with Hooks enabled (Settings → Beta → Hooks).",
                "Folder ~/.cursor/ writable.",
                "Reload the Cursor window after enabling hooks."
            ]
        case .vscode:
            return [
                "VS Code with the GitHub Copilot Chat extension installed.",
                "Hooks live in ~/.claude/settings.json (shared with Claude Code).",
                "Reload the VS Code window after install for hooks to register."
            ]
        case .copilotCLI:
            return [
                "GitHub Copilot CLI installed (npm-global, gh-extension, brew, or volta/n).",
                "For each project you want tracked, click ‘Add folder’ and pick its repo root.",
                "Hooks file is created at <repo>/.github/hooks/doomcoder.json."
            ]
        }
    }

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
