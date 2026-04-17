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
                // Fire a `.wait` event so it clears the `isAttention` guard in
                // IPhoneRelay.fire; `.info` events are intentionally dropped
                // because real info-level progress isn't worth a push.
                let synthetic = AgentEvent(
                    src: .manual,
                    agent: session.agent,
                    status: .wait,
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
            case .live:          return .ready
            case .configWritten: return .warn
            case .modified:      return .warn
            case .notInstalled:  return .off
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
            switch MCPInstaller.status(for: mcp) {
            case .live:          return "live"
            case .configWritten: return "config written · restart agent"
            case .modified:      return "modified (user-authored)"
            case .notInstalled:  return "not installed"
            case .missingConfig: return "config unreadable"
            }
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
            let s = MCPInstaller.status(for: mcp)
            return s == .configWritten || s == .live
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
        // For hook agents, run the real round-trip test — it's the ground
        // truth for whether hook.sh actually reaches DoomCoder. For
        // non-hook agents (MCP-only), fall back to the synthetic inject.
        if let info, info.tier == .hook,
           let hook = HookInstaller.Agent(rawValue: info.id) {
            busy = true
            lastActionOutput = "Running round-trip test…"
            Task {
                defer { busy = false }
                let res = await HookRoundTripTest.run(
                    agent: hook,
                    statusManager: agentStatus
                )
                switch res {
                case .success(let s):
                    lastActionOutput = "✓ Round-trip \(s.millis) ms — hook → DoomCoder pipe is live."
                case .failure(let f):
                    lastActionOutput = "✗ \(f.errorDescription ?? "round-trip failed")"
                }
            }
            return
        }
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
                        iPhoneRelay.sendTest(channelID: channelID)
                    }
                    .disabled(!isReady)

                    if isReady && !isActive {
                        Button {
                            iPhoneRelay.selectedChannelID = channelID
                        } label: {
                            Label("Set as Active", systemImage: "checkmark.circle")
                        }
                    }

                    Spacer()
                }

                if isActive {
                    Text("This is the active delivery method. All agent alerts will be sent through \(kind.displayName).")
                        .font(.callout)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
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
            StatusBadge(isReady ? .ready : .off)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName).font(.title2).bold()
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var description: String {
        switch kind {
        case .ntfy: return "HTTPS push via ntfy.sh — subscribe from the ntfy iOS app, no account required."
        }
    }

    private var isReady: Bool {
        switch kind {
        case .ntfy: return iPhoneRelay.ntfy.isReady
        }
    }

    private var channelID: String {
        switch kind {
        case .ntfy: return "ntfy"
        }
    }

    private var isActive: Bool {
        iPhoneRelay.activeChannel?.info.id == channelID
    }

    private var recentDeliveries: [IPhoneRelay.Delivery] {
        let name = kind.displayName
        return iPhoneRelay.deliveryLog.filter { $0.channel == name }.prefix(8).map { $0 }
    }

    private var infoGrid: some View {
        VStack(spacing: 0) {
            gridRow("Ready", isReady ? "Yes" : "No")
            Divider()
            gridRow("Active", isActive ? "Yes" : "No")
            switch kind {
            case .ntfy:
                Divider()
                gridRow("Topic", iPhoneRelay.ntfy.topic.isEmpty ? "—" : iPhoneRelay.ntfy.topic, monospaced: true)
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
    let socketServer: SocketServer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch kind {
                case .deliveryLog: deliverySection
                }
            }
            .padding(20)
        }
    }

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

            activeMethodPicker
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

    /// Dropdown to pick which iPhone delivery method is active. Shows only
    /// channels whose setup is complete (`isReady`), plus a "None" sentinel
    /// to silence delivery without uninstalling anything. When no channel is
    /// ready, the picker is disabled and shows a call-to-action.
    private var activeMethodPicker: some View {
        let available = iPhoneRelay.availableChannels
        let activeID = iPhoneRelay.activeChannel?.info.id ?? ""
        let noneTag = "__none__"

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .foregroundStyle(.blue)
                Text("Active delivery method")
                    .font(.headline)
                Spacer()
            }

            if available.isEmpty {
                HStack {
                    Text("No channels configured yet. Open an iPhone Channel in the sidebar to set one up.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
            } else {
                Picker("Send agent alerts via", selection: Binding(
                    get: {
                        iPhoneRelay.selectedChannelID == noneTag ? noneTag : activeID
                    },
                    set: { newValue in
                        iPhoneRelay.selectedChannelID = (newValue == noneTag ? noneTag : newValue)
                    }
                )) {
                    ForEach(available) { info in
                        Label(info.displayName, systemImage: info.icon).tag(info.id)
                    }
                    Divider()
                    Text("None — silence iPhone alerts").tag(noneTag)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)

                Text(activeID.isEmpty || iPhoneRelay.selectedChannelID == noneTag
                     ? "Delivery is paused — no events will reach your iPhone."
                     : "All agent alerts will be sent through \(iPhoneRelay.activeChannel?.info.displayName ?? "the selected channel").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
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
