import SwiftUI

// MARK: - SessionDetailPane
//
// Shown when a live session row is selected. Displays the session's current
// state, elapsed time, last message, and a "Send Test Notification" button
// that fires the real iPhoneRelay pipeline.

struct SessionDetailPane: View {
    let session: AgentSession
    @Bindable var iPhoneRelay: IPhoneRelay

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                infoGrid
                if let msg = session.lastMessage, !msg.isEmpty {
                    messageCard(msg)
                }
                actionsCard
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    // MARK: - Cards

    private var headerCard: some View {
        HStack(spacing: 14) {
            StatusBadge(badgeTone)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName).font(.title2).bold()
                Text(subtitleText).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var badgeTone: StatusBadge.Tone {
        switch session.state {
        case .active:  return .live
        case .waiting: return .warn
        case .errored: return .error
        case .done:    return .ready
        }
    }

    private var subtitleText: String {
        var parts: [String] = []
        switch session.state {
        case .active:  parts.append("Working")
        case .waiting: parts.append("Needs input")
        case .errored: parts.append("Error")
        case .done:    parts.append("Done")
        }
        parts.append("elapsed \(session.elapsedText)")
        if let repo = session.repoName { parts.append(repo) }
        parts.append("via \(session.source.rawValue)")
        return parts.joined(separator: " · ")
    }

    private var infoGrid: some View {
        VStack(spacing: 0) {
            gridRow("Agent", session.displayName)
            Divider()
            gridRow("Session", session.id)
            if let tool = session.currentTool {
                Divider()
                gridRow("Current tool", tool)
            }
            Divider()
            gridRow("Tool calls", "\(session.toolCount)")
            if let cwd = session.cwd {
                Divider()
                gridRow("Working dir", cwd, monospaced: true)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
        }
    }

    private func gridRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func messageCard(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last message").font(.caption).foregroundStyle(.secondary)
            Text(msg).font(.body).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
        }
    }

    private var actionsCard: some View {
        HStack {
            Button {
                let synthetic = AgentEvent(
                    src: .manual,
                    agent: session.agent,
                    status: .info,
                    sessionId: session.id,
                    cwd: session.cwd,
                    message: "Test from DoomCoder — this session's settings."
                )
                iPhoneRelay.fire(event: synthetic, session: session)
            } label: {
                Label("Send Test Notification", systemImage: "bell.badge.fill")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            Text("Fires the real iPhone pipeline for this session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AgentDetailPane
//
// Shown when an agent is selected in the sidebar. Displays install status,
// tier, config path, backups, and the primary "Set up" / "Reinstall" /
// "Uninstall" actions. All logic reuses the existing installer types.

struct AgentDetailPane: View {
    let agentId: String
    @Bindable var iPhoneRelay: IPhoneRelay
    @Bindable var agentStatus: AgentStatusManager
    let openSetup: () -> Void

    @State private var lastActionOutput: String = ""
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                infoGrid
                actions
                if !lastActionOutput.isEmpty {
                    outputBox
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private var info: AgentCatalog.Info? { AgentCatalog.info(forId: agentId) }

    private var header: some View {
        HStack(spacing: 14) {
            StatusBadge(statusTone)
            VStack(alignment: .leading, spacing: 2) {
                Text(info?.displayName ?? agentId).font(.title2).bold()
                Text(tierSubtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var tierSubtitle: String {
        guard let info else { return "Unknown agent" }
        switch info.tier {
        case .hook: return "Hook integration · deterministic"
        case .mcp:  return "MCP server integration"
        }
    }

    private var statusTone: StatusBadge.Tone {
        if let info, info.tier == .hook,
           let hook = HookInstaller.Agent(rawValue: info.id) {
            switch HookInstaller.status(for: hook) {
            case .installed: return .ready
            case .partial:   return .warn
            case .notInstalled: return .off
            case .missingHookScript: return .error
            }
        }
        if let info, info.tier == .mcp,
           let mcp = MCPInstaller.Agent.allCases.first(where: { $0.catalogId == info.id }) {
            switch MCPInstaller.status(for: mcp) {
            case .installed: return .ready
            case .modified:  return .warn
            case .notInstalled: return .off
            case .missingConfig: return .error
            }
        }
        return .off
    }

    private var statusText: String {
        if let info, info.tier == .hook,
           let hook = HookInstaller.Agent(rawValue: info.id) {
            return HookInstaller.status(for: hook).label
        }
        if let info, info.tier == .mcp,
           let mcp = MCPInstaller.Agent.allCases.first(where: { $0.catalogId == info.id }) {
            return MCPInstaller.status(for: mcp).rawValue
        }
        return "unknown"
    }

    private var configPath: String {
        if let info, info.tier == .hook,
           let hook = HookInstaller.Agent(rawValue: info.id) {
            return HookInstaller.configPath(for: hook)
        }
        if let info, info.tier == .mcp,
           let mcp = MCPInstaller.Agent.allCases.first(where: { $0.catalogId == info.id }) {
            return mcp.configPath.path
        }
        return "—"
    }

    private var infoGrid: some View {
        VStack(spacing: 0) {
            gridRow("Status", statusText)
            Divider()
            gridRow("Config", configPath, monospaced: true)
            Divider()
            gridRow("Session count", "\(sessionsForThisAgent)")
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
        }
    }

    private var sessionsForThisAgent: Int {
        agentStatus.sessions.filter { $0.agent == agentId }.count
    }

    private func gridRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                openSetup()
            } label: {
                Label(isInstalled ? "Reinstall…" : "Set up…", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.borderedProminent)

            if isInstalled {
                Button("Uninstall") { runUninstall() }
                    .disabled(busy)
            }

            Button("Send Test") { sendTest() }
                .disabled(busy)

            Spacer()
        }
    }

    private var isInstalled: Bool {
        if let info, info.tier == .hook,
           let hook = HookInstaller.Agent(rawValue: info.id) {
            if case .installed = HookInstaller.status(for: hook) { return true }
        }
        if let info, info.tier == .mcp,
           let mcp = MCPInstaller.Agent.allCases.first(where: { $0.catalogId == info.id }) {
            return MCPInstaller.status(for: mcp) == .installed
        }
        return false
    }

    private var outputBox: some View {
        ScrollView {
            Text(lastActionOutput)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(minHeight: 80, maxHeight: 200)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.04))
        }
    }

    private func runUninstall() {
        busy = true
        Task {
            defer { busy = false }
            do {
                if let info, info.tier == .hook,
                   let hook = HookInstaller.Agent(rawValue: info.id) {
                    let msg = try HookInstaller.uninstall(hook)
                    lastActionOutput = "✓ Uninstalled\n\(msg)"
                } else if let info, info.tier == .mcp,
                          let mcp = MCPInstaller.Agent.allCases.first(where: { $0.catalogId == info.id }) {
                    _ = try MCPInstaller.uninstall(mcp)
                    lastActionOutput = "✓ Uninstalled \(mcp.displayName)"
                }
            } catch {
                lastActionOutput = "✗ \(error.localizedDescription)"
            }
        }
    }

    private func sendTest() {
        agentStatus.injectTest(
            agent: agentId,
            status: .wait,
            message: "Test from DoomCoder — AgentTracking"
        )
        lastActionOutput = "✓ Fired a synthetic 'needs input' event. Check the menu bar and iPhone channels."
    }
}

// MARK: - ChannelDetailPane

struct ChannelDetailPane: View {
    let kind: AgentTrackingSelection.ChannelKind
    @Bindable var iPhoneRelay: IPhoneRelay
    let openSetup: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                infoGrid
                HStack {
                    Button {
                        openSetup()
                    } label: {
                        Label(isReady ? "Reconfigure…" : "Set up…", systemImage: "gear")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Send Test") {
                        iPhoneRelay.sendTest(channel: channelTestKey)
                    }
                    .disabled(!isEnabled)

                    Spacer()
                }
                if !recentDeliveries.isEmpty {
                    DeliveryLogList(deliveries: recentDeliveries)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            StatusBadge(isEnabled && isReady ? .ready : .off)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName).font(.title2).bold()
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var description: String {
        switch kind {
        case .reminder: return "Writes a completed reminder to your iCloud list — shows up on iPhone in seconds."
        case .imessage: return "Sends an iMessage to the handle you configure. Fastest delivery, requires Messages automation permission."
        case .ntfy:     return "HTTPS push via ntfy.sh — works even when you're off the Apple ecosystem."
        }
    }

    private var isEnabled: Bool {
        switch kind {
        case .reminder: return iPhoneRelay.reminder.isEnabled
        case .imessage: return iPhoneRelay.imessage.isEnabled
        case .ntfy:     return iPhoneRelay.ntfy.isEnabled
        }
    }

    private var isReady: Bool {
        switch kind {
        case .reminder: return iPhoneRelay.reminder.isReady
        case .imessage: return iPhoneRelay.imessage.isReady
        case .ntfy:     return iPhoneRelay.ntfy.isReady
        }
    }

    private var channelTestKey: String {
        switch kind {
        case .reminder: return "Reminder"
        case .imessage: return "iMessage"
        case .ntfy:     return "ntfy"
        }
    }

    private var recentDeliveries: [IPhoneRelay.Delivery] {
        let key = channelTestKey
        return iPhoneRelay.deliveryLog.filter { $0.channel == key }.prefix(8).map { $0 }
    }

    private var infoGrid: some View {
        VStack(spacing: 0) {
            gridRow("Enabled", isEnabled ? "Yes" : "No")
            Divider()
            gridRow("Ready", isReady ? "Yes" : "No")
            switch kind {
            case .imessage:
                Divider()
                gridRow("Handle", iPhoneRelay.imessage.handle.isEmpty ? "—" : iPhoneRelay.imessage.handle, monospaced: true)
            case .ntfy:
                Divider()
                gridRow("Topic", iPhoneRelay.ntfy.topic.isEmpty ? "—" : iPhoneRelay.ntfy.topic, monospaced: true)
            case .reminder:
                EmptyView()
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
        }
    }

    private func gridRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - SystemDetailPane

struct SystemDetailPane: View {
    let kind: AgentTrackingSelection.SystemKind
    @Bindable var iPhoneRelay: IPhoneRelay
    @Bindable var focusManager: FocusFilterManager
    let socketServer: SocketServer

    @State private var focusOutput = ""
    @State private var icloudOutput = ""
    @State private var icloudBusy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch kind {
                case .focus:       focusSection
                case .icloud:      icloudSection
                case .deliveryLog: deliverySection
                }
            }
            .padding(20)
        }
    }

    // MARK: Focus

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                StatusBadge(focusManager.isEnabled ? .ready : .off)
                VStack(alignment: .leading) {
                    Text("Focus Filter").font(.title2).bold()
                    Text("Toggle any macOS or iOS Focus mode when an agent is working.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Toggle("Donate Focus filter events", isOn: Binding(
                get: { focusManager.isEnabled },
                set: { focusManager.isEnabled = $0 }
            ))

            Text("""
            How to use it:
            1. Open System Settings → Focus → (pick a mode, e.g. Do Not Disturb).
            2. Scroll to **Focus Filters** → Add Filter → **DoomCoder — Agent Working**.
            3. Set it to turn ON when the filter is Active.
            With this toggle on, DoomCoder donates the filter state every time an \
            AI agent starts or stops — so the Focus mode follows your agent \
            automatically, on this Mac and on any iPhone sharing the same Focus.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Button("Run Focus Test") {
                    focusOutput = "Running test…"
                    Task {
                        focusOutput = await focusManager.runTest()
                    }
                }
                .buttonStyle(.borderedProminent)

                if let last = focusManager.lastDonationAt {
                    let activeStr = focusManager.lastDonationActive ? "true" : "false"
                    Text("Last donation: \(last.formatted(date: .omitted, time: .standard)) (active=\(activeStr))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()
            }

            if let err = focusManager.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if !focusOutput.isEmpty {
                Text(focusOutput)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.04))
                    }
            }
        }
    }

    // MARK: iCloud

    private var icloudSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                StatusBadge(iPhoneRelay.reminder.isReady ? .ready : .off)
                VStack(alignment: .leading) {
                    Text("iCloud Round-Trip").font(.title2).bold()
                    Text("Prove Reminders propagate through iCloud end to end.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("""
            The test writes a hidden marker reminder to your default list, \
            then polls iCloud (via a fresh EKEventStore) until the marker comes \
            back. On success the reminder is removed and the latency is shown. \
            If it times out, you'll know your iPhone isn't receiving from this \
            Mac — usually because Reminders → iCloud sync is off.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Button {
                    icloudBusy = true
                    icloudOutput = "Running — may take up to 15s…"
                    Task {
                        let result = await iPhoneRelay.reminder.runICloudRoundTripTest()
                        switch result {
                        case .success(let latency):
                            icloudOutput = String(format: "✓ Propagated in %.2fs. Your iPhone will receive agent events.", latency)
                        case .failure(let err):
                            icloudOutput = "✗ \(err.localizedDescription)"
                        }
                        icloudBusy = false
                    }
                } label: {
                    Label("Run Round-Trip Test", systemImage: "arrow.triangle.2.circlepath.icloud")
                }
                .buttonStyle(.borderedProminent)
                .disabled(icloudBusy || !iPhoneRelay.reminder.isReady)

                Spacer()
            }

            if !icloudOutput.isEmpty {
                Text(icloudOutput)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.04))
                    }
            }
        }
    }

    // MARK: Delivery log

    private var deliverySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                StatusBadge(iPhoneRelay.deliveryLog.isEmpty ? .off : .ready)
                VStack(alignment: .leading) {
                    Text("Delivery Log").font(.title2).bold()
                    Text("Last \(iPhoneRelay.deliveryLog.count) iPhone delivery attempts.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            socketStatus

            if iPhoneRelay.deliveryLog.isEmpty {
                Text("No deliveries yet. Trigger a test from an agent or channel row to populate this log.")
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity)
            } else {
                DeliveryLogList(deliveries: Array(iPhoneRelay.deliveryLog.prefix(50)))
            }
        }
    }

    private var socketStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: socketServer.isRunning ? "network.badge.shield.half.filled" : "network.slash")
                .foregroundStyle(socketServer.isRunning ? .green : .red)
            Text("Socket: \(socketServer.isRunning ? "listening" : "offline")  ·  \(socketServer.socketPath)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if let err = socketServer.lastError {
                Text("— \(err)").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(.regularMaterial)
        }
    }
}

// MARK: - DeliveryLogList

struct DeliveryLogList: View {
    let deliveries: [IPhoneRelay.Delivery]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(deliveries) { d in
                HStack(spacing: 10) {
                    Image(systemName: d.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(d.success ? .green : .red)
                        .imageScale(.small)
                    Text(d.timestamp.formatted(date: .omitted, time: .standard)).font(.system(.caption, design: .monospaced)).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
                    Text(d.channel).font(.caption).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
                    Text(d.title).font(.caption).lineLimit(1)
                    Spacer()
                    Text(d.detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.regularMaterial)
        }
    }
}
