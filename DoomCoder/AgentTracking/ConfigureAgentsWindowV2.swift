import SwiftUI
import CoreImage
import UserNotifications

// v2 configure window — NavigationSplitView with Agents + Channels + Logs tabs.
// Replaces the v1 wizard with accordion-style detail pane and per-agent
// actions (install, uninstall, reveal, open-in-IDE, demo, verify).
struct ConfigureAgentsViewV2: View {
    enum Tab: Hashable { case agents, channels, logs }
    @State private var tab: Tab = .agents
    @State private var selected: TrackedAgent? = .claude
    @State private var detections: [TrackedAgent: AgentDetection] = [:]
    @State private var statusMessage: String = ""
    @State private var statusIsError: Bool = false
    @State private var isInstalling: Bool = false
    @State private var showMigrationAlert = false
    @State private var migrationAgents: [TrackedAgent] = []
    // Copilot CLI folders
    @State private var cliFolders: [URL] = CopilotCLIFolderManager.folders
    @State private var installedCache: [TrackedAgent: Bool] = [:]
    // Channel store
    @State private var channelConfig = ChannelStore.load()
    // Channel test results
    @State private var testResult: (Bool, String)? = nil
    // Hook validation warnings (human-readable drift diff per agent)
    @State private var hookWarnings: [TrackedAgent: String] = [:]
    // Copilot CLI folders whose last verification failed — used to target
    // Repair to the specific failing folders instead of a blanket reinstall.
    @State private var cliFailingFolders: [URL] = []
    // Permission status
    @State private var permStatus: String = "…"
    // Notification event preferences
    @State private var notifPrefs = ChannelStore.loadPrefs()
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
                        .id(agent)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermStatus()
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
                        withAnimation(DCAnim.fade) {
                            tab = .agents
                            selected = agent
                        }
                    } label: {
                        agentRow(agent)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        (tab == .agents && selected == agent)
                        ? Color.accentColor.opacity(0.15) : Color.clear
                    )
                    .animation(DCAnim.fade, value: tab == .agents && selected == agent)
                }
            }

            Section {
                Button {
                    withAnimation(DCAnim.fade) {
                        tab = .channels
                        selected = nil
                    }
                } label: {
                    Label("Channels", systemImage: "bell.badge")
                }
                .buttonStyle(.plain)
                .listRowBackground(tab == .channels ? Color.accentColor.opacity(0.15) : Color.clear)
                .animation(DCAnim.fade, value: tab == .channels)

                Button {
                    withAnimation(DCAnim.fade) {
                        tab = .logs
                        selected = nil
                    }
                } label: {
                    Label("Logs", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.plain)
                .listRowBackground(tab == .logs ? Color.accentColor.opacity(0.15) : Color.clear)
                .animation(DCAnim.fade, value: tab == .logs)
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
                                    .animation(DCAnim.smooth, value: eventCount > 0)
                                Text(eventCount > 0 ? "Active" : "Quiet")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(eventCount > 0 ? .primary : .secondary)
                                    .contentTransition(.identity)
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Hook Validation Warning — shows the concrete drift diff
                // (missing events / stale helper paths / failing folders)
                // rather than a blanket external-modification banner.
                if let warning = hookWarnings[agent] {
                    GroupBox {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(warning)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Repair") {
                                repairDriftedHooks(agent: agent)
                            }
                        }
                    } label: {
                        Label("Hook Warning", systemImage: "exclamationmark.shield")
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
                                    withAnimation(DCAnim.smooth) { isInstalling = true; statusMessage = "" }
                                    let r = AgentInstallerV2.install(agent)
                                    let msg = resultMessage(r, verb: "Install")
                                    let isErr: Bool
                                    if case .failure = r { isErr = true } else { isErr = false }
                                    withAnimation(DCAnim.smooth) {
                                        statusMessage = msg
                                        statusIsError = isErr
                                        isInstalling = false
                                    }
                                    Task { await detectAllAsync() }
                                }
                                .disabled(isInstalling)
                                if isInst {
                                    Button("Uninstall", role: .destructive) {
                                        withAnimation(DCAnim.smooth) { isInstalling = true; statusMessage = "" }
                                        let r = AgentInstallerV2.uninstall(agent)
                                        let msg = resultMessage(r, verb: "Uninstall")
                                        let isErr: Bool
                                        if case .failure = r { isErr = true } else { isErr = false }
                                        withAnimation(DCAnim.smooth) {
                                            statusMessage = msg
                                            statusIsError = isErr
                                            isInstalling = false
                                        }
                                        Task { await detectAllAsync() }
                                    }
                                    .disabled(isInstalling)
                                }
                                if isInstalling {
                                    ProgressView()
                                        .controlSize(.small)
                                        .transition(.opacity)
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

                // Verify — single inline Connection Doctor (replaces the
                // old Test Helper / Run Demo / Watch Live trio).
                ConnectionDoctorSection(agent: agent)

                // Live Events
                liveEventsSection(agent)

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
                    HStack(spacing: 6) {
                        Image(systemName: statusIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(statusIsError ? .red : .green)
                        Text(statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Spacer()
                        if statusIsError, let agent = selected {
                            Button("Show Config") {
                                let path = AgentInstallerV2.configPath(for: agent)
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                            }
                            .buttonStyle(.borderless)
                            .font(.callout)
                        }
                    }
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(20)
        }
    }

    // MARK: - Copilot CLI folders

    private var copilotCLIFoldersSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if cliFolders.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No project folders registered")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Copilot CLI hooks are installed per-project. Add your project folders below to track agent activity.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                ForEach(cliFolders, id: \.path) { folder in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.secondary)
                        Text(folder.lastPathComponent)
                            .font(.callout.bold())
                        Text(folder.path)
                            .lineLimit(1).truncationMode(.middle)
                            .font(.caption).foregroundStyle(.tertiary)
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

                Divider()

                HStack(spacing: 8) {
                    Button("Add Folder…") {
                        let p = NSOpenPanel()
                        p.canChooseFiles = false
                        p.canChooseDirectories = true
                        p.allowsMultipleSelection = true
                        p.prompt = "Add Project"
                        if p.runModal() == .OK {
                            for url in p.urls {
                                CopilotCLIFolderManager.addFolder(url)
                            }
                            cliFolders = CopilotCLIFolderManager.folders
                        }
                    }

                    Button("Discover Projects") {
                        let discovered = CopilotCLIFolderManager.discoverRecentFolders()
                            .filter { d in !cliFolders.contains(where: { $0.path == d.path }) }
                        for url in discovered.prefix(5) {
                            CopilotCLIFolderManager.addFolder(url)
                        }
                        withAnimation(DCAnim.smooth) {
                            cliFolders = CopilotCLIFolderManager.folders
                        }
                    }
                    .help("Scans ~/Developer, ~/Projects, ~/Code, ~/Desktop for project folders")

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
                            Image(systemName: "lock.circle.fill").foregroundStyle(.orange)
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

                // Notification event preferences
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        notifPrefToggle("Session completed", $notifPrefs.sessionEnd)
                        notifPrefToggle("Errors", $notifPrefs.error)
                        notifPrefToggle("Permission requests", $notifPrefs.permissionNeeded)
                        notifPrefToggle("Agent responses", $notifPrefs.agentResponse)
                        Divider()
                        notifPrefToggle("Session started", $notifPrefs.sessionStart)
                        notifPrefToggle("Sub-agent activity", $notifPrefs.subagentStart)
                        notifPrefToggle("Tool usage", $notifPrefs.toolUse)
                    }
                } label: {
                    Label("Notify me when…", systemImage: "bell.badge")
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

    // MARK: - Live Events

    @ViewBuilder
    private func liveEventsSection(_ agent: TrackedAgent) -> some View {
        let store = LiveEventsStore.shared
        let events = store.events(for: agent)
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                // Toolbar row
                HStack {
                    Spacer()

                    Button(role: .destructive) {
                        store.clear(agent: agent)
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(events.isEmpty)
                }

                Divider()

                // Events scroll area
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if events.isEmpty {
                                Text("No events yet — install hooks and use the agent, or run the Connection Doctor above.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 20)
                            } else {
                                ForEach(events) { ev in
                                    LiveEventRow(event: ev)
                                        .id(ev.id)
                                        .transition(.asymmetric(
                                            insertion: .push(from: .bottom).combined(with: .opacity),
                                            removal: .opacity
                                        ))
                                }
                            }
                        }
                    }
                    .frame(height: 180)
                    .onChange(of: events.count) { _, _ in
                        if let last = events.last {
                            withAnimation(DCAnim.fade) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Live Events", systemImage: "antenna.radiowaves.left.and.right")
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
        withAnimation(DCAnim.smooth) {
            detections = d
            installedCache = results.1
            cliFolders = CopilotCLIFolderManager.folders
        }
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
        var failingFolders: [URL] = []
        for agent in TrackedAgent.allCases {
            guard installedCache[agent] == true else { continue }
            if agent == .copilotCLI {
                // Per-folder verification: treat the agent as healthy as
                // long as *any* registered folder is OK. Surface the diff
                // for any folder that actually fails so the user can act
                // on it.
                let results = AgentInstallerV2.verifyAllCLIFolders()
                if results.isEmpty { continue }
                var failureMessages: [String] = []
                for (folder, result) in results {
                    if case .failure(let err) = result {
                        failingFolders.append(folder)
                        failureMessages.append(err.localizedDescription)
                    }
                }
                if !failureMessages.isEmpty {
                    warnings[agent] = failureMessages.joined(separator: "\n")
                }
            } else {
                if case .failure(let err) = AgentInstallerV2.verifyInstalled(agent) {
                    warnings[agent] = err.localizedDescription
                }
            }
        }
        withAnimation(DCAnim.smooth) {
            hookWarnings = warnings
            cliFailingFolders = failingFolders
        }
    }

    /// Repairs hook configs when drift was detected. For Copilot CLI this
    /// reinstalls *only* the folders that failed verification instead of
    /// blanket-reinstalling every registered folder.
    private func repairDriftedHooks(agent: TrackedAgent) {
        if agent == .copilotCLI && !cliFailingFolders.isEmpty {
            var failures: [String] = []
            for folder in cliFailingFolders {
                if case .failure(let err) = AgentInstallerV2.install(.copilotCLI, folder: folder) {
                    failures.append("\(folder.lastPathComponent): \(err.localizedDescription)")
                }
            }
            statusMessage = failures.isEmpty
                ? "Repair successful — reinstalled \(cliFailingFolders.count) folder\(cliFailingFolders.count == 1 ? "" : "s")."
                : "Repair failed for:\n\(failures.joined(separator: "\n"))"
            statusIsError = !failures.isEmpty
        } else {
            let r = AgentInstallerV2.install(agent)
            statusMessage = resultMessage(r, verb: "Repair")
            if case .failure = r { statusIsError = true } else { statusIsError = false }
        }
        Task { await detectAllAsync(); validateAllHooks() }
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

    private func notifPrefToggle(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(label, isOn: Binding(
            get: { binding.wrappedValue },
            set: { v in
                binding.wrappedValue = v
                ChannelStore.savePrefs(notifPrefs)
            }
        ))
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    private func resultMessage(_ r: Result<Void, Error>, verb: String) -> String {
        switch r {
        case .success: return "\(verb) successful."
        case .failure(let e):
            var msg = "\(verb) failed: \(e.localizedDescription)"
            if let verifyErr = e as? AgentInstallerV2.VerifyError,
               let suggestion = verifyErr.recoverySuggestion {
                msg += " \(suggestion)"
            }
            return msg
        }
    }
}

// MARK: - LiveEventRow

private struct LiveEventRow: View {
    let event: LiveEvent
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DCAnim.snap) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(event.timeLabel)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)

                    Text(event.event)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(event.synthetic ? .purple : .primary)

                    if !event.shortCwd.isEmpty {
                        Text(event.shortCwd)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if event.payloadJSON != nil {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let json = event.payloadJSON {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(json)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().opacity(0.4)
        }
    }
}

// MARK: - Connection Doctor

/// Inline step-wizard that replaces the old Test Helper / Run Demo /
/// Watch Live / liveEventsSection Test button row. Runs a fixed sequence
/// of checks that trace the full path from the dc-hook binary through
/// the unix socket into a macOS local notification. Each step renders
/// with a status pill (pending/running/ok/warn/fail) and an optional
/// Fix CTA so the user can act on the specific failure.
struct ConnectionDoctorSection: View {
    let agent: TrackedAgent

    enum StepStatus: Equatable {
        case pending
        case running
        case ok
        case warn
        case fail
    }

    struct DoctorStep: Identifiable, Equatable {
        let id: Int
        let title: String
        var detail: String
        var status: StepStatus
        var fixTitle: String?
    }

    @State private var steps: [DoctorStep] = Self.initialSteps()
    @State private var running = false
    @State private var summary: String? = nil
    @State private var summaryIsGood: Bool = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        Task { await runDoctor() }
                    } label: {
                        if running {
                            Label("Running…", systemImage: "stopwatch")
                        } else {
                            Label("Run Doctor", systemImage: "stethoscope")
                        }
                    }
                    .disabled(running)

                    Spacer()

                    if let summary {
                        HStack(spacing: 6) {
                            Image(systemName: summaryIsGood ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(summaryIsGood ? .green : .orange)
                            Text(summary)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }

                Divider().opacity(0.4)

                ForEach(steps) { step in
                    stepRow(step)
                }
            }
            .animation(DCAnim.smooth, value: steps)
            .animation(DCAnim.fade, value: summary)
        } label: {
            Label("Connection Doctor", systemImage: "waveform.path.ecg")
        }
    }

    @ViewBuilder
    private func stepRow(_ step: DoctorStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusPill(step.status)
                .frame(width: 70, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.callout.weight(.medium))
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if (step.status == .fail || step.status == .warn), let fix = step.fixTitle {
                Button(fix) {
                    Task { await applyFix(for: step) }
                }
                .controlSize(.small)
                .disabled(running)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusPill(_ status: StepStatus) -> some View {
        switch status {
        case .pending:
            Label("pending", systemImage: "circle")
                .foregroundStyle(.tertiary)
                .font(.caption2)
                .labelStyle(.titleAndIcon)
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("running").font(.caption2).foregroundStyle(.secondary)
            }
        case .ok:
            Label("ok", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption2)
        case .warn:
            Label("warn", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption2)
        case .fail:
            Label("fail", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption2)
        }
    }

    // MARK: - Steps

    private static func initialSteps() -> [DoctorStep] {
        [
            DoctorStep(id: 0, title: "Helper binary present",
                       detail: "Checks dc-hook exists at its stable path and is executable.",
                       status: .pending, fixTitle: "Reinstall helper"),
            DoctorStep(id: 1, title: "Socket listening",
                       detail: "Confirms the in-app unix socket is bound and accepting connections.",
                       status: .pending, fixTitle: "Restart listener"),
            DoctorStep(id: 2, title: "Config parsed & events mapped",
                       detail: "Verifies every expected hook event is mapped to the correct binary.",
                       status: .pending, fixTitle: "Repair"),
            DoctorStep(id: 3, title: "End-to-end ping round-trip",
                       detail: "Sends dc-hook --ping and waits for the envelope to arrive over the socket.",
                       status: .pending, fixTitle: "Check helper permissions"),
            DoctorStep(id: 4, title: "Notification dispatch",
                       detail: "Posts a local test notification via macOS Notification Center.",
                       status: .pending, fixTitle: "Open notification settings")
        ]
    }

    // MARK: - Run

    private func runDoctor() async {
        running = true
        summary = nil
        steps = Self.initialSteps()
        var failures = 0
        var firstFailedIndex: Int? = nil

        for idx in steps.indices {
            if firstFailedIndex != nil { break }
            setStatus(idx, .running)
            let outcome = await runStep(idx)
            setStatus(idx, outcome.status, detail: outcome.detail)
            if outcome.status == .fail || outcome.status == .warn {
                failures += 1
                if firstFailedIndex == nil { firstFailedIndex = idx }
            }
        }

        running = false
        if failures == 0 {
            summary = "Connected ✨"
            summaryIsGood = true
        } else {
            summary = "\(failures) issue\(failures == 1 ? "" : "s") found"
            summaryIsGood = false
        }
    }

    private struct StepOutcome {
        let status: StepStatus
        let detail: String
    }

    private func runStep(_ idx: Int) async -> StepOutcome {
        switch idx {
        case 0: return checkHelperBinary()
        case 1: return checkSocketListening()
        case 2: return checkConfigMapping()
        case 3: return await checkEndToEndPing()
        case 4: return await checkNotificationDispatch()
        default: return StepOutcome(status: .ok, detail: "")
        }
    }

    private func setStatus(_ idx: Int, _ status: StepStatus, detail: String? = nil) {
        guard idx < steps.count else { return }
        var step = steps[idx]
        step.status = status
        if let detail { step.detail = detail }
        steps[idx] = step
    }

    // MARK: - Step implementations

    private func checkHelperBinary() -> StepOutcome {
        let path = AgentInstallerV2.helperBinaryPath()
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            return StepOutcome(status: .fail, detail: "Not found at \(path).")
        }
        if !fm.isExecutableFile(atPath: path) {
            return StepOutcome(status: .fail, detail: "Not executable: \(path).")
        }
        return StepOutcome(status: .ok, detail: "Found at \(path).")
    }

    private func checkSocketListening() -> StepOutcome {
        if HookSocketListener.shared.isRunning {
            return StepOutcome(status: .ok, detail: "Listener bound and accepting connections.")
        }
        return StepOutcome(status: .fail, detail: "In-app unix socket listener is not running.")
    }

    private func checkConfigMapping() -> StepOutcome {
        if agent == .copilotCLI {
            let results = AgentInstallerV2.verifyAllCLIFolders()
            if results.isEmpty {
                return StepOutcome(status: .warn, detail: "No project folders registered — add one to enable CLI tracking.")
            }
            var failingFolders: [String] = []
            for (folder, result) in results {
                if case .failure(let err) = result {
                    failingFolders.append("\(folder.lastPathComponent): \(err.localizedDescription)")
                }
            }
            if failingFolders.isEmpty {
                return StepOutcome(status: .ok, detail: "All \(results.count) folder(s) verified.")
            }
            return StepOutcome(status: .fail, detail: failingFolders.joined(separator: "\n"))
        } else {
            switch AgentInstallerV2.verifyInstalled(agent) {
            case .success:
                return StepOutcome(status: .ok, detail: "All expected hook events mapped.")
            case .failure(let err):
                return StepOutcome(status: .fail, detail: err.localizedDescription)
            }
        }
    }

    private func checkEndToEndPing() async -> StepOutcome {
        // Register a one-shot observer on the shared socket listener so
        // we can confirm the envelope actually made the round-trip.
        let listener = HookSocketListener.shared
        let pidStr = String(ProcessInfo.processInfo.processIdentifier)
        let box = EnvelopeBox()
        listener.setTestObserver { env in
            if env.event.lowercased() == "unknown" || env.event.lowercased().contains("ping") {
                box.signal(env)
            }
        }
        defer { listener.setTestObserver(nil) }

        let helperPath = AgentInstallerV2.helperBinaryPath()
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            return StepOutcome(status: .fail, detail: "Helper binary missing or not executable.")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helperPath)
        proc.arguments = ["--ping"]
        do {
            try proc.run()
        } catch {
            return StepOutcome(status: .fail, detail: "Failed to launch dc-hook --ping: \(error.localizedDescription)")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            return StepOutcome(status: .fail, detail: "dc-hook --ping exited with status \(proc.terminationStatus). Host pid: \(pidStr).")
        }

        // Wait up to 5s for an envelope to arrive via the socket.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if box.received { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if box.received {
            return StepOutcome(status: .ok, detail: "Ping envelope received on socket within 5s.")
        }
        return StepOutcome(status: .fail, detail: "dc-hook --ping exited 0 but no envelope arrived on the socket within 5s.")
    }

    private func checkNotificationDispatch() async -> StepOutcome {
        let disp = NotificationDispatcher.shared
        let granted: Bool = await withCheckedContinuation { cont in
            disp.requestPermission { ok in cont.resume(returning: ok) }
        }
        if !granted {
            return StepOutcome(status: .fail, detail: "macOS notifications are not authorized for DoomCoder.")
        }
        let content = UNMutableNotificationContent()
        content.title = "DoomCoder · Doctor"
        content.body = "Connection Doctor test — this is not a real agent event."
        content.categoryIdentifier = "doomcoder.doctor"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(req)
            return StepOutcome(status: .ok, detail: "Test notification posted. You should see a banner momentarily.")
        } catch {
            return StepOutcome(status: .fail, detail: "Failed to post notification: \(error.localizedDescription)")
        }
    }

    // MARK: - Fixes

    private func applyFix(for step: DoctorStep) async {
        switch step.id {
        case 0:
            _ = AgentInstallerV2.ensureStableHelper()
        case 1:
            // Restart listener in-place. The primary callback is owned by
            // the AppDelegate, so stop+start without a new callback is
            // deliberately skipped — we ping again instead.
            HookSocketListener.shared.stop()
            // Give the raw fd time to close + rebind via AppDelegate
            // lifecycle. We don't re-subscribe the primary callback from
            // here. The user can relaunch if the listener is wedged.
            try? await Task.sleep(nanoseconds: 400_000_000)
        case 2:
            if agent == .copilotCLI {
                for folder in CopilotCLIFolderManager.folders {
                    _ = AgentInstallerV2.install(.copilotCLI, folder: folder)
                }
            } else {
                _ = AgentInstallerV2.install(agent)
            }
        case 3:
            // Nothing we can do programmatically — point user at perms.
            NSWorkspace.shared.selectFile(AgentInstallerV2.helperBinaryPath(),
                                          inFileViewerRootedAtPath: "")
        case 4:
            NotificationDispatcher.shared.openSystemSettings()
        default:
            break
        }
        await runDoctor()
    }
}

/// Thread-safe one-shot flag used by the end-to-end ping step to signal
/// when the expected envelope arrives from the socket listener.
private final class EnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _received = false
    var received: Bool { lock.lock(); defer { lock.unlock() }; return _received }
    func signal(_ env: HookEnvelope) {
        lock.lock(); _received = true; lock.unlock()
    }
}
