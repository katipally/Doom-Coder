import SwiftUI
import CoreImage
import UserNotifications

// v2 configure window — NavigationSplitView with Agents + Channels + Logs tabs.
// Replaces the v1 wizard with accordion-style detail pane and per-agent
// actions (install, uninstall, reveal, open-in-IDE, demo, verify).
struct ConfigureAgentsViewV2: View {
    enum Tab: Hashable { case agents, channels, logs, settings }
    /// Set by `WindowOpener.openSettings()` before the window is created so a
    /// cold-opened Configure window lands on the right tab (the
    /// `.dcSelectConfigureTab` notification only reaches an already-live view).
    @MainActor static var pendingTab: Tab?
    @State private var tab: Tab = .agents
    @State private var selected: TrackedAgent? = .claude
    @State private var advancedExpanded = false
    @State private var detections: [TrackedAgent: AgentDetection] = [:]
    @State private var statusMessage: String = ""
    @State private var statusIsError: Bool = false
    @State private var isInstalling: Bool = false
    @State private var showMigrationAlert = false
    @State private var migrationAgents: [TrackedAgent] = []
    @State private var installedCache: [TrackedAgent: Bool] = [:]
    // VS Code variants — which settings.json files the user wants patched.
    @State private var vscodeEnabledVariants: [String] = AgentInstallerV2.vscodeEnabledVariantPaths()
    // Channel store
    @State private var channelConfig = ChannelStore.load()
    // Channel test results
    @State private var testResult: (Bool, String)? = nil
    // Hook validation warnings (human-readable drift diff per agent)
    @State private var hookWarnings: [TrackedAgent: String] = [:]
    // Permission status
    @State private var permStatus: String = "…"
    // Periodic health refresh
    private let healthTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            Group {
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
                case .settings:
                    ConfigureSettingsPane(sleepManager: SleepManager.shared)
                }
            }
            .navigationTitle(detailTitle)
        }
        .frame(minWidth: 820, minHeight: 580)
        .onAppear {
            if let pending = Self.pendingTab {
                Self.pendingTab = nil
                tab = pending
                if pending != .agents { selected = nil }
            }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .doomCoderIconsRefreshed)) { _ in
            detectAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dcSelectConfigureTab)) { note in
            guard let id = note.object as? String else { return }
            withAnimation(DCAnim.fade) {
                switch id {
                case "settings":  tab = .settings; selected = nil
                case "ai":        tab = .settings; selected = nil
                case "channels":  tab = .channels; selected = nil
                case "logs":      tab = .logs;     selected = nil
                case "agents":    tab = .agents
                default: break
                }
            }
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
                    Label("Connections", systemImage: "antenna.radiowaves.left.and.right")
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

                Button {
                    withAnimation(DCAnim.fade) {
                        tab = .settings
                        selected = nil
                    }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                .listRowBackground(tab == .settings ? Color.accentColor.opacity(0.15) : Color.clear)
                .animation(DCAnim.fade, value: tab == .settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Configure")
    }

    /// Titlebar text that follows the current selection.
    private var detailTitle: String {
        switch tab {
        case .agents:   return selected?.displayName ?? "Agents"
        case .channels: return "Connections"
        case .logs:     return "Logs"
        case .settings: return "Settings"
        }
    }

    @ViewBuilder
    private func agentRow(_ agent: TrackedAgent) -> some View {
        let d = detections[agent]
        let isInst = installedCache[agent] ?? false
        let hasWarning = hookWarnings[agent] != nil
        HStack(spacing: 8) {
            AgentIconView(agent: agent, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName).font(.body)
                Text(d?.installed == true ? (d?.version ?? "installed") : "not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasWarning {
                HelpTip("DoomCoder detected that the installed hook config no longer matches what it wrote — likely edited by the agent or another tool. Select this agent and click Repair to restore it.")
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                    .accessibilityHidden(true)
            } else if d?.installed == true && !isInst {
                // Agent detected but hooks not installed: nudge
                Text("Set up →")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if isInst {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .accessibilityHidden(true)
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
                    AgentIconView(agent: agent, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.displayName).font(.title.bold())
                        Text(subtitle(agent)).foregroundStyle(.secondary)
                    }
                }

                // ① Setup — install / uninstall hooks for this agent.
                hooksSetupSection(agent)

                // ② Notify — editable per-agent notification card (NotifyAboutCard.swift).
                NotifyAboutCard(agent: agent)

                // Status
                if !statusMessage.isEmpty {
                    statusBanner
                }

                // ③ Advanced — diagnostics tucked away so the default view stays clean.
                advancedSection(agent)
            }
            .padding(20)
        }
    }

    // MARK: - Advanced (card-style collapsible)

    @ViewBuilder
    private func advancedSection(_ agent: TrackedAgent) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(DCAnim.smooth) { advancedExpanded.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wrench.adjustable")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Advanced")
                                .font(.body.weight(.semibold))
                            Text("Diagnostics, prerequisites & logs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if advancedExpanded {
                    VStack(alignment: .leading, spacing: 16) {
                        detectionSection(agent)
                        if installedCache[agent] == true { healthSection(agent) }
                        if let warning = hookWarnings[agent] { hookWarningSection(agent, warning: warning) }
                        prerequisitesSection(agent)
                        ConnectionDoctorSection(agent: agent)
                        liveEventsSection(agent)
                    }
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - Agent detail sections

    @ViewBuilder
    private func detectionSection(_ agent: TrackedAgent) -> some View {
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
    }

    @ViewBuilder
    private func healthSection(_ agent: TrackedAgent) -> some View {
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
                        .accessibilityHidden(true)
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
    }

    @ViewBuilder
    private func hookWarningSection(_ agent: TrackedAgent, warning: String) -> some View {
        GroupBox {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
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
    }

    @ViewBuilder
    private func prerequisitesSection(_ agent: TrackedAgent) -> some View {
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
    }

    @ViewBuilder
    private func hooksSetupSection(_ agent: TrackedAgent) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Config: \(configPathHint(agent))")
                    .font(.callout).foregroundStyle(.secondary)

                if agent == .vscode {
                    vscodeVariantsPicker
                }

                HStack(spacing: 12) {
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
            Label("Setup", systemImage: "link")
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(statusIsError ? .red : .green)
                .accessibilityHidden(true)
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

    // MARK: - VS Code variants picker

    /// Checkbox group that lets users opt in/out of each detected VS Code
    /// variant's settings.json patch. Order: Stable, Insiders, VSCodium,
    /// Cursor, Windsurf.
    private var vscodeVariantsPicker: some View {
        let labels: [(path: String, name: String)] = [
            (NSHomeDirectory() + "/Library/Application Support/Code/User/settings.json", "VS Code"),
            (NSHomeDirectory() + "/Library/Application Support/Code - Insiders/User/settings.json", "VS Code Insiders"),
            (NSHomeDirectory() + "/Library/Application Support/VSCodium/User/settings.json", "VSCodium"),
            (NSHomeDirectory() + "/Library/Application Support/Cursor/User/settings.json", "Cursor"),
            (NSHomeDirectory() + "/Library/Application Support/Windsurf/User/settings.json", "Windsurf"),
        ]
        let detected = labels.filter { FileManager.default.fileExists(atPath: $0.path) }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Patch settings.json in:").font(.caption).foregroundStyle(.secondary)
            if detected.isEmpty {
                Text("No VS Code-family installs detected.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(detected, id: \.path) { variant in
                    Toggle(isOn: Binding(
                        get: { vscodeEnabledVariants.contains(variant.path) },
                        set: { on in
                            var arr = vscodeEnabledVariants
                            if on, !arr.contains(variant.path) { arr.append(variant.path) }
                            if !on { arr.removeAll { $0 == variant.path } }
                            vscodeEnabledVariants = arr
                            AgentInstallerV2.setVSCodeEnabledVariants(arr)
                        }
                    )) {
                        Text(variant.name).font(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Channels tab

    private var channelsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connections").font(.title.bold())
                Text("Where alerts get delivered.")
                    .foregroundStyle(.secondary)

                // Permission Status

                // Permission Status
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

                // iPhone / iPad (iCloud)
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

                        Text("Mirror notifications to the DoomCoder companion app on your iPhone or iPad via iCloud. Sign in to the same iCloud account on both devices — no servers, no tokens.")
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

                // Test result
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
            .padding(20)
        }
    }

    // MARK: - Live events

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
                inst[a] = AgentInstallerV2.isInstalled(a)
            }
            return (dets, inst)
        }.value
        var d: [TrackedAgent: AgentDetection] = [:]
        for det in results.0 { d[det.agent] = det }
        withAnimation(DCAnim.smooth) {
            detections = d
            installedCache = results.1
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
            let hooksDir = AgentInstallerV2.vscodeCopilotHooksDirAbsolute()
            list.append(Prereq(label: "~/.copilot/vscode-hooks/ writable", met: FileManager.default.isWritableFile(atPath: hooksDir) || !FileManager.default.fileExists(atPath: hooksDir), fix: "Check permissions on ~/.copilot/vscode-hooks/"))
            list.append(Prereq(label: "VS Code Copilot Chat extension installed", met: true, fix: nil))
        case .copilotCLI:
            list.append(Prereq(label: "GitHub Copilot CLI installed", met: detections[.copilotCLI]?.installed == true, fix: "Install via npm: `npm i -g @github/copilot`"))
            list.append(Prereq(label: "~/.copilot/ exists", met: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.copilot"), fix: "Run `copilot` once to initialize"))
        case .windsurf:
            let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codeium/windsurf")
            list.append(Prereq(label: "~/.codeium/windsurf/ exists", met: FileManager.default.fileExists(atPath: dir.path), fix: "Install Windsurf and open it once"))
            list.append(Prereq(label: "Windsurf installed", met: detections[.windsurf]?.installed == true, fix: "Download from windsurf.com"))
        case .codexCLI:
            let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
            list.append(Prereq(label: "~/.codex/ exists", met: FileManager.default.fileExists(atPath: dir.path), fix: "Run `codex` once to initialize"))
            list.append(Prereq(label: "Codex CLI installed", met: detections[.codexCLI]?.installed == true, fix: "Install via npm: `npm i -g @openai/codex`"))
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
            if case .failure(let err) = AgentInstallerV2.verifyInstalled(agent) {
                warnings[agent] = err.localizedDescription
            }
        }
        withAnimation(DCAnim.smooth) {
            hookWarnings = warnings
        }
    }

    /// Reinstalls hooks for an agent when drift was detected.
    private func repairDriftedHooks(agent: TrackedAgent) {
        let r = AgentInstallerV2.install(agent)
        statusMessage = resultMessage(r, verb: "Repair")
        if case .failure = r { statusIsError = true } else { statusIsError = false }
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
                "Hooks live in ~/.copilot/vscode-hooks/doomcoder.json. We patch each variant's settings.json to point chat.hookFilesLocations at this directory.",
                "Reload the VS Code window after install for hooks to register."
            ]
        case .copilotCLI:
            return [
                "GitHub Copilot CLI installed (`npm i -g @github/copilot` or `brew install copilot-cli`).",
                "Hooks file is created at ~/.copilot/hooks/doomcoder.json — global, applies to every directory you run `copilot` in.",
                "Run `copilot` once so ~/.copilot/ is created."
            ]
        case .windsurf:
            return [
                "Windsurf installed (download from windsurf.com).",
                "Open Windsurf at least once so ~/.codeium/windsurf/ is created.",
                "Folder ~/.codeium/windsurf/ writable."
            ]
        case .codexCLI:
            return [
                "OpenAI Codex CLI installed (`npm i -g @openai/codex`).",
                "Run `codex` once so ~/.codex/ is created.",
                "Hooks written to ~/.codex/hooks.json; feature flag `codex_hooks = true` added to ~/.codex/config.toml."
            ]
        }
    }

    private func subtitle(_ agent: TrackedAgent) -> String {
        switch agent {
        case .claude:     return "Hooks in ~/.claude/settings.json (nested matcher format)"
        case .cursor:     return "Hooks in ~/.cursor/hooks.json (version: 1, command only)"
        case .vscode:     return "Hooks in ~/.copilot/vscode-hooks/doomcoder.json (chat.hookFilesLocations)"
        case .copilotCLI: return "Hooks in ~/.copilot/hooks/doomcoder.json (global, all 13 events)"
        case .windsurf:   return "Hooks in ~/.codeium/windsurf/hooks.json (command only)"
        case .codexCLI:   return "Hooks in ~/.codex/hooks.json + codex_hooks feature flag"
        }
    }

    private func configPathHint(_ agent: TrackedAgent) -> String {
        switch agent {
        case .claude:     return "~/.claude/settings.json"
        case .cursor:     return "~/.cursor/hooks.json"
        case .vscode:     return "~/.copilot/vscode-hooks/doomcoder.json"
        case .copilotCLI: return "~/.copilot/hooks/doomcoder.json"
        case .windsurf:   return "~/.codeium/windsurf/hooks.json"
        case .codexCLI:   return "~/.codex/hooks.json"
        }
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
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded, let json = event.payloadJSON {
                PayloadRendererView(json: json)
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
                                .accessibilityHidden(true)
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
        switch AgentInstallerV2.verifyInstalled(agent) {
        case .success:
            return StepOutcome(status: .ok, detail: "All expected hook events mapped.")
        case .failure(let err):
            return StepOutcome(status: .fail, detail: err.localizedDescription)
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
            _ = AgentInstallerV2.install(agent)
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
