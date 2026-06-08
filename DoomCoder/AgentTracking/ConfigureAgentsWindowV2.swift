import SwiftUI
import CoreImage
import UserNotifications
import DoomCoderCore

// v2 configure window — NavigationSplitView with Agents + Channels + Logs tabs.
// Replaces the v1 wizard with accordion-style detail pane and per-agent
// actions (install, uninstall, reveal, open-in-IDE, demo, verify).
struct ConfigureAgentsViewV2: View {
    @State private var router = AppRouter.shared
    @State private var tab: AppRouter.ConfigTab = .agents
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
    @State private var showAddDevice = false
    @State private var shareCoordinator = MacShareCoordinator.shared
    // Periodic health refresh
    private let healthTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private static let companionAppStoreURL = "https://apps.apple.com/app/doomcoder-companion/id6772514212"
    private static let companionHelpURL = "https://github.com/katipally/Doom-Coder#iphone--ipad-companion"

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
                case .activity:
                    ActivityView()
                case .settings:
                    ConfigureSettingsPane(sleepManager: SleepManager.shared)
                }
            }
            .navigationTitle(detailTitle)
        }
        .frame(minWidth: 820, minHeight: 580)
        .onAppear {
            // Sync from `AppRouter.shared.configureTab` so a cold-opened
            // Configure window lands on the right tab. This replaces the
            // racy `Self.pendingTab` static + `dcSelectConfigureTab`
            // notification pattern.
            tab = router.configureTab
            if router.configureTab != .agents { selected = nil }
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
        .onChange(of: router.configureTab) { _, newValue in
            // React to live router updates (e.g. when the user opens
            // Settings from the menu bar while the Configure window is
            // already open). `withAnimation(DCAnim.fade)` smooths the
            // tab swap.
            withAnimation(DCAnim.fade) {
                tab = newValue
                if newValue != .agents { selected = nil }
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
                    HStack {
                        Label("Connections", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if !shareCoordinator.participants.isEmpty {
                            Text("\(shareCoordinator.participants.count)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                                .foregroundStyle(.tint)
                                .accessibilityLabel("\(shareCoordinator.participants.count) participants")
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(tab == .channels ? Color.accentColor.opacity(0.15) : Color.clear)
                .animation(DCAnim.fade, value: tab == .channels)

                Button {
                    withAnimation(DCAnim.fade) {
                        tab = .activity
                        selected = nil
                    }
                } label: {
                    Label("Activity", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.plain)
                .listRowBackground(tab == .activity ? Color.accentColor.opacity(0.15) : Color.clear)
                .animation(DCAnim.fade, value: tab == .activity)

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
        case .activity: return "Activity"
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
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connections").font(.title2.bold())
                    Text("Where alerts get delivered, and the devices connected to this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                connectedDevicesSection

                sharedWithSection

                permissionsCard

                channelsCard

                Spacer(minLength: 8)
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddDevice = true
                } label: {
                    Label("Add Device…", systemImage: "plus.circle.fill")
                }
                .help("Pair a new iPhone or iPad via QR code or invite link")
                .accessibilityLabel("Add Device")
            }
        }
        .sheet(isPresented: $showAddDevice) {
            AddDeviceSheet()
        }
        .task { await shareCoordinator.refresh() }
    }

    // MARK: - Permissions card (merged "Permission Status" + iCloud readiness)

    private var permissionsCard: some View {
        ConnectionsCard(
            title: "Permissions",
            symbol: "lock.shield"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                permissionsRow(
                    symbol: "bell.badge.fill",
                    title: "macOS Notifications",
                    status: notificationPermissionStatus()
                ) {
                    notificationPermissionAction()
                }
                Divider().opacity(0.4)
                permissionsRow(
                    symbol: "iphone.gen3",
                    title: "Mirror to iPhone and iPad",
                    status: iCloudMirrorStatus()
                ) {
                    EmptyView()
                }
            }
        }
    }

    private func notificationPermissionStatus() -> (symbol: String, tint: Color, text: String) {
        switch NotificationDispatcher.shared.permissionStatus {
        case .authorized, .provisional, .ephemeral:
            return ("checkmark.circle.fill", .green, "Allowed")
        case .denied:
            return ("bell.slash.fill", .orange, "Off — open System Settings")
        case .notDetermined:
            return ("questionmark.circle", .blue, "Not asked yet")
        @unknown default:
            return ("questionmark.circle", .secondary, "Unknown")
        }
    }

    @ViewBuilder
    private func notificationPermissionAction() -> some View {
        let status = NotificationDispatcher.shared.permissionStatus
        switch status {
        case .denied:
            Button("Open Settings") { NotificationDispatcher.shared.openSystemSettings() }
                .controlSize(.small)
        case .notDetermined:
            Button("Allow") {
                NotificationDispatcher.shared.requestPermission { _ in refreshPermStatus() }
            }
            .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func iCloudMirrorStatus() -> (symbol: String, tint: Color, text: String) {
        if CloudKitPusher.shared.isReady {
            return ("checkmark.icloud.fill", .green, "Ready as \(CloudKitPusher.shared.macName)")
        }
        return ("icloud.slash", .secondary, "Connecting to iCloud…")
    }

    @ViewBuilder
    private func permissionsRow(
        symbol: String,
        title: String,
        status: (symbol: String, tint: Color, text: String),
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                HStack(spacing: 5) {
                    Image(systemName: status.symbol)
                        .font(.caption2)
                        .foregroundStyle(status.tint)
                        .accessibilityHidden(true)
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            action()
        }
    }

    // MARK: - Channels card (per-channel toggles + inline test results)

    private var channelsCard: some View {
        ConnectionsCard(
            title: "Notification channels",
            symbol: "bell.fill"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                channelRow(
                    label: "Mac notifications",
                    symbol: "bell.fill",
                    binding: Binding(
                        get: { channelConfig.global.macNotification },
                        set: { v in
                            channelConfig.global.macNotification = v
                            ChannelStore.setGlobal(channelConfig.global)
                            if v { NotificationDispatcher.shared.requestPermission() }
                        }
                    ),
                    lastTest: macLastTest,
                    onTest: {
                        ChannelTester.sendTest(channel: .macNotification) { ok, msg in
                            recordTest(.macNotification, ok: ok, msg: msg)
                        }
                    }
                )
                Divider().opacity(0.4)
                channelRow(
                    label: "iPhone and iPad (iCloud)",
                    symbol: "iphone.gen3",
                    binding: Binding(
                        get: { channelConfig.global.cloudkit },
                        set: { v in
                            channelConfig.global.cloudkit = v
                            ChannelStore.setGlobal(channelConfig.global)
                        }
                    ),
                    lastTest: cloudkitLastTest,
                    onTest: {
                        ChannelTester.sendTest(channel: .cloudKit) { ok, msg in
                            recordTest(.cloudKit, ok: ok, msg: msg)
                        }
                    }
                )
            }
        }
    }

    @State private var macLastTest: TestRecord?
    @State private var cloudkitLastTest: TestRecord?

    struct TestRecord: Equatable {
        let ok: Bool
        let msg: String
        let ts: Date
    }

    private func recordTest(_ channel: ChannelTester.Channel, ok: Bool, msg: String) {
        let rec = TestRecord(ok: ok, msg: msg, ts: Date())
        withAnimation(DCAnim.micro) {
            switch channel {
            case .macNotification: macLastTest = rec
            case .cloudKit:        cloudkitLastTest = rec
            }
        }
    }

    @ViewBuilder
    private func channelRow(
        label: String,
        symbol: String,
        binding: Binding<Bool>,
        lastTest: TestRecord?,
        onTest: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.callout.weight(.medium))
                Spacer()
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(label)
                Button("Send test", action: onTest)
                    .controlSize(.small)
            }
            if let lastTest {
                HStack(spacing: 6) {
                    Image(systemName: lastTest.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(lastTest.ok ? .green : .red)
                        .accessibilityHidden(true)
                    Text(lastTest.msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(lastTest.ts, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 34)  // aligns with the label column
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Shared with (CKShare participants — different iCloud accounts)

    @ViewBuilder
    private var sharedWithSection: some View {
        if !shareCoordinator.participants.isEmpty {
            ConnectionsCard(
                title: "Shared with (different iCloud)",
                symbol: "person.2.badge.gearshape"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shareCoordinator.participants) { p in
                        participantRow(p)
                    }
                    Text("People on a different iCloud account who accepted your invite. Removing one revokes their access immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func participantRow(_ p: ShareParticipantInfo) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.displayName).font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    if let email = p.email, !email.isEmpty {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                    let status = p.acceptanceStatus
                    if !status.isEmpty {
                        participantStatusPill(status)
                    }
                }
            }
            Spacer()
            Button(role: .destructive) {
                Task { await shareCoordinator.removeParticipant(id: p.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Revoke this iCloud account's access")
            .accessibilityLabel("Remove \(p.displayName)")
        }
    }

    @ViewBuilder
    private func participantStatusPill(_ status: String) -> some View {
        let isPending = status.lowercased().contains("pending")
        let tint: Color = isPending ? .orange : .green
        Text(status.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 0.5)
            )
    }

    // MARK: - Connected devices (companion presence)

    @ViewBuilder
    private var connectedDevicesSection: some View {
        // Periodic tick so "Connected" ages out to "Last seen X ago" while the
        // window stays open, even with no new heartbeat to trigger a re-render.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let store = CompanionStatusStore.shared
            let devices = store.devices
            ConnectionsCard(
                title: "Devices on your iCloud",
                symbol: "iphone.gen3",
                trailingAction: {
                    AnyView(
                        Button {
                            showAddDevice = true
                        } label: {
                            Label("Add Device", systemImage: "plus.circle")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                        .help("Pair a new iPhone or iPad")
                    )
                }
            ) {
                if devices.isEmpty {
                    emptyDevicesState
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(devices, id: \.deviceId) { device in
                            deviceRow(device, now: context.date)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyDevicesState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "iphone.slash")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No iPhone or iPad connected yet")
                    .font(.callout.weight(.medium))
                Spacer()
            }
            Text("Install DoomCoder on your iPhone or iPad and sign in to the same iCloud account. It will appear here automatically. Or pair an existing device with a QR code or invite link.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                // Inline primary CTA — the user's complaint was that the
                // toolbar's `+` icon was not discoverable. This prominent
                // button in the body of the section makes pairing
                // reachable without scanning for a tiny toolbar glyph.
                Button {
                    showAddDevice = true
                } label: {
                    Label("Add Device", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("Add Device")
                .help("Pair a new iPhone or iPad via QR code or invite link")

                Button {
                    if let url = URL(string: Self.companionAppStoreURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Get the app", systemImage: "arrow.down.app.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Open the App Store to download DoomCoder on an iPhone or iPad")

                Button {
                    if let url = URL(string: Self.companionHelpURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("How it works")
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: CompanionStatusRecord, now: Date) -> some View {
        let connected = now.timeIntervalSince(device.lastSeen) < CompanionStatusStore.connectedThreshold
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: connected ? "circle.fill" : "circle")
                .font(.system(size: 9))
                .foregroundStyle(connected ? .green : .secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName.isEmpty ? "iPhone or iPad" : device.displayName)
                    .font(.callout.weight(.medium))
                let detail = [device.model, device.systemVersion]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if connected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("Last seen \(Self.relativeTime(device.lastSeen, now: now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !connected {
                Button {
                    forgetDevice(device.deviceId)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Forget this device")
                .accessibilityLabel("Forget \(device.displayName.isEmpty ? "device" : device.displayName)")
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Forget Device", systemImage: "trash") {
                forgetDevice(device.deviceId)
            }
        }
    }

    /// Removes a device from the local list and queues a CloudKit delete of its
    /// presence record. Stable device IDs mean a live device just re-registers;
    /// stale ghosts (old reinstalls) stay gone.
    private func forgetDevice(_ deviceId: String) {
        CompanionStatusStore.shared.remove(deviceId: deviceId)
        CloudKitPusher.shared.deleteCompanionStatus(deviceId: deviceId)
    }

    /// Compact "5m ago" / "2h ago" / "3d ago" relative timestamp.
    private static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

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
        case .opencode:
            let dir = AgentInstallerV2.opencodeConfigDir()
            list.append(Prereq(label: "opencode installed", met: detections[.opencode]?.installed == true, fix: "Install from opencode.ai (CLI or app)"))
            list.append(Prereq(label: "~/.config/opencode/ writable", met: FileManager.default.isWritableFile(atPath: dir) || !FileManager.default.fileExists(atPath: dir), fix: "Check permissions on the opencode config directory"))
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
        case .opencode:
            return [
                "opencode installed (CLI/TUI or the desktop app) — from opencode.ai.",
                "We install a plugin at ~/.config/opencode/plugin/doomcoder.js (honors OPENCODE_CONFIG_DIR). It auto-loads for every project, in both the CLI and the app.",
                "No tokens used: the plugin forwards lifecycle events to the dc-hook helper."
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
        case .opencode:   return "Plugin in ~/.config/opencode/plugin/doomcoder.js (CLI + app)"
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
        case .opencode:   return "~/.config/opencode/plugin/doomcoder.js"
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
//
// Moved to its own file: `DoomCoder/AgentTracking/LiveEventRow.swift`.

// MARK: - Connection Doctor / ConnectionsCard / AddDeviceSheet
//
// All three have been moved to their own files in `DoomCoder/AgentTracking/`:
// - ConnectionDoctorSection.swift
// - ConnectionsCard.swift
// - AddDeviceSheet.swift
