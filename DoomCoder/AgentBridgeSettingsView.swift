import SwiftUI

// MARK: - AgentBridgeSettingsView
//
// One tab inside the Settings window. Each supported agent gets a dedicated
// card with a live status badge, plain-English description, one-click Setup
// button, a "What we changed" disclosure, Reveal / Restore-backup / Uninstall
// controls, and a "Send Test Notification" button. A live-sessions dashboard
// at the top shows every active agent with real-time state (working / waiting
// / error / done) sourced directly from AgentStatusManager.

struct AgentBridgeSettingsView: View {

    @Bindable var agentStatus: AgentStatusManager
    var socketServer: SocketServer

    @State private var claudeStatus: HookInstaller.Status = .notInstalled
    @State private var copilotStatus: HookInstaller.Status = .notInstalled
    @State private var mcpStatuses: [MCPInstaller.Agent: MCPInstaller.Status] = [:]
    @State private var banner: Banner?
    @State private var isWorking = false

    struct Banner: Identifiable {
        let id = UUID()
        let kind: Kind
        let message: String
        enum Kind { case success, error, info }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                bridgeStatus
                if !agentStatus.sessions.isEmpty {
                    liveSessionsCard
                }
                if let banner { bannerView(banner) }

                hookAgentCard(
                    agent: .claudeCode,
                    status: claudeStatus,
                    refresh: { claudeStatus = HookInstaller.status(for: .claudeCode) }
                )
                hookAgentCard(
                    agent: .copilotCLI,
                    status: copilotStatus,
                    refresh: { copilotStatus = HookInstaller.status(for: .copilotCLI) }
                )

                mcpSectionHeader

                ForEach(MCPInstaller.Agent.allCases) { mcp in
                    mcpAgentCard(agent: mcp)
                }

                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 560)
        .onAppear { refreshAll() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent Bridge")
                .font(.title2).bold()
            Text("DoomCoder connects directly to your AI coding agents so it can keep your Mac awake, show progress, and notify your iPhone the moment a task is done — without using any tokens.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bridgeStatus: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: socketServer.isRunning ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                    .font(.title2)
                    .foregroundStyle(socketServer.isRunning ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(socketServer.isRunning ? "Bridge listening" : "Bridge offline")
                        .font(.headline)
                    Text(socketServer.isRunning
                         ? "Socket: \(socketServer.socketPath)"
                         : (socketServer.lastError ?? "Not started yet."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if !agentStatus.sessions.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(agentStatus.sessions.count) live")
                            .font(.caption).bold()
                        Text("session\(agentStatus.sessions.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        }
    }

    // Live agent sessions currently being tracked. Each row updates in real time
    // from AgentStatusManager.sessions (@Observable), so state flips (wait / done /
    // error) appear without any manual refresh.
    private var liveSessionsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                    Text("Live sessions")
                        .font(.headline)
                    Spacer()
                    Text("Updates in real time")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(agentStatus.sessions) { session in
                    sessionRow(session)
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(sessionStateColor(session.state))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayName).font(.callout).bold()
                    if let repo = session.repoName, !repo.isEmpty {
                        Text("· \(repo)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text(sessionStateLabel(session.state))
                        .font(.caption2)
                        .foregroundStyle(sessionStateColor(session.state))
                    if let tool = session.currentTool, !tool.isEmpty {
                        Text("• \(tool)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if session.toolCount > 0 {
                        Text("• \(session.toolCount) tool call\(session.toolCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(session.elapsedText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func sessionStateColor(_ state: AgentSession.State) -> Color {
        switch state {
        case .active:  return .green
        case .waiting: return .orange
        case .errored: return .red
        case .done:    return .secondary
        }
    }

    private func sessionStateLabel(_ state: AgentSession.State) -> String {
        switch state {
        case .active:  return "Working"
        case .waiting: return "Waiting for input"
        case .errored: return "Error"
        case .done:    return "Done"
        }
    }

    private func bannerView(_ banner: Banner) -> some View {
        HStack(spacing: 10) {
            Image(systemName: bannerIcon(banner.kind))
                .foregroundStyle(bannerColor(banner.kind))
            Text(banner.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { self.banner = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(bannerColor(banner.kind).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var mcpSectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MCP-based agents")
                .font(.headline)
            Text("These editors support the Model Context Protocol. DoomCoder installs itself as a tiny MCP server (~/.doomcoder/mcp.py) and exposes a single \"dc\" tool the agent calls on every state change — ultra-cheap on tokens and fully deterministic.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func mcpAgentCard(agent: MCPInstaller.Agent) -> some View {
        let status = mcpStatuses[agent] ?? .notInstalled
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "cpu")
                        .font(.title3)
                    Text(agent.displayName).font(.headline)
                    Spacer()
                    mcpStatusBadge(status)
                }

                Text(agent.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        performMCPSetup(agent: agent)
                    } label: {
                        Label(mcpPrimaryLabel(for: status), systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || !socketServer.isRunning || !MCPRuntime.isDeployed)

                    if status == .installed {
                        Button(role: .destructive) {
                            performMCPUninstall(agent: agent)
                        } label: {
                            Label("Uninstall", systemImage: "trash")
                        }
                        .disabled(isWorking)
                    }

                    Button {
                        sendMCPTest(for: agent)
                    } label: {
                        Label("Send Test Notification", systemImage: "paperplane")
                    }
                    .disabled(isWorking)
                }

                DisclosureGroup("What we changed") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(agent.configPath.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button {
                                revealInFinder(path: agent.configPath.path)
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            Button {
                                performMCPRestore(agent: agent)
                            } label: {
                                Label("Restore Backup", systemImage: "arrow.uturn.backward")
                            }
                            .disabled((try? MCPInstaller.latestBackup(for: agent)) == nil)
                        }
                        .font(.caption)

                        if status == .modified {
                            Text("An entry called \"doomcoder\" already exists without our sentinel. Re-run Setup to take ownership, or remove it manually.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !MCPRuntime.isDeployed {
                            Text("The MCP runner script hasn't been deployed yet. Quit DoomCoder and relaunch to refresh ~/.doomcoder/mcp.py.")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .font(.caption)
            }
            .padding(6)
        }
    }

    private func mcpStatusBadge(_ s: MCPInstaller.Status) -> some View {
        let (label, color, icon): (String, Color, String) = {
            switch s {
            case .installed:      return ("Connected",   .green,     "checkmark.seal.fill")
            case .modified:       return ("Conflict",    .orange,    "exclamationmark.triangle.fill")
            case .notInstalled:   return ("Not set up",  .secondary, "circle")
            case .missingConfig:  return ("Unreadable",  .red,       "xmark.octagon.fill")
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label).bold()
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }

    private func mcpPrimaryLabel(for s: MCPInstaller.Status) -> String {
        switch s {
        case .installed:     return "Reinstall"
        case .modified:      return "Take Ownership"
        default:             return "Set Up"
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How it works")
                .font(.headline)
            Text("Hooks fire short shell commands inside your agent for events like SessionStart, PreToolUse, Stop, and Notification. Those commands pipe a single line of JSON into DoomCoder's Unix socket at ~/.doomcoder/dc.sock. The agent never sees DoomCoder — no tokens are spent and your sessions behave exactly as before.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: - Agent card

    @ViewBuilder
    private func hookAgentCard(
        agent: HookInstaller.Agent,
        status: HookInstaller.Status,
        refresh: @escaping () -> Void
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.title3)
                    Text(agent.displayName).font(.headline)
                    Spacer()
                    statusBadge(status)
                }

                Text(agent.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        performSetup(agent: agent, refresh: refresh)
                    } label: {
                        Label(primaryLabel(for: status), systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || !socketServer.isRunning)

                    if status.isInstalled {
                        Button(role: .destructive) {
                            performUninstall(agent: agent, refresh: refresh)
                        } label: {
                            Label("Uninstall", systemImage: "trash")
                        }
                        .disabled(isWorking)
                    }

                    Button {
                        sendTest(for: agent)
                    } label: {
                        Label("Send Test Notification", systemImage: "paperplane")
                    }
                    .disabled(isWorking)
                }

                DisclosureGroup("What we changed") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(HookInstaller.configPath(for: agent))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button {
                                revealInFinder(path: HookInstaller.configPath(for: agent))
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            Button {
                                restoreBackup(agent: agent, refresh: refresh)
                            } label: {
                                Label("Restore Backup", systemImage: "arrow.uturn.backward")
                            }
                            .disabled(HookInstaller.latestBackup(for: agent) == nil)
                        }
                        .font(.caption)

                        if case .partial(_, let reason) = status {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .font(.caption)
            }
            .padding(6)
        }
    }

    // MARK: - Badge / labels

    private func statusBadge(_ s: HookInstaller.Status) -> some View {
        let (label, color, icon): (String, Color, String) = {
            switch s {
            case .installed:         return ("Connected",    .green,   "checkmark.seal.fill")
            case .partial:           return ("Partial",      .orange,  "exclamationmark.triangle.fill")
            case .notInstalled:      return ("Not set up",   .secondary, "circle")
            case .missingHookScript: return ("Needs restart", .red,    "xmark.octagon.fill")
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label).bold()
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }

    private func primaryLabel(for s: HookInstaller.Status) -> String {
        switch s {
        case .installed: return "Reinstall"
        case .partial:   return "Repair"
        default:         return "Set Up"
        }
    }

    private func bannerIcon(_ k: Banner.Kind) -> String {
        switch k {
        case .success: return "checkmark.circle.fill"
        case .error:   return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    private func bannerColor(_ k: Banner.Kind) -> Color {
        switch k {
        case .success: return .green
        case .error:   return .red
        case .info:    return .accentColor
        }
    }

    // MARK: - Actions

    private func refreshAll() {
        claudeStatus  = HookInstaller.status(for: .claudeCode)
        copilotStatus = HookInstaller.status(for: .copilotCLI)
        var mcp: [MCPInstaller.Agent: MCPInstaller.Status] = [:]
        for a in MCPInstaller.Agent.allCases { mcp[a] = MCPInstaller.status(for: a) }
        mcpStatuses = mcp
    }

    private func performSetup(agent: HookInstaller.Agent, refresh: @escaping () -> Void) {
        isWorking = true
        defer { isWorking = false }
        do {
            let path = try HookInstaller.install(agent)
            banner = Banner(kind: .success, message: "\(agent.displayName) is now connected. Wrote \(path).")
        } catch {
            banner = Banner(kind: .error, message: error.localizedDescription)
        }
        refresh()
    }

    private func performUninstall(agent: HookInstaller.Agent, refresh: @escaping () -> Void) {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try HookInstaller.uninstall(agent)
            banner = Banner(kind: .info, message: "Removed DoomCoder from \(agent.displayName). A backup was saved.")
        } catch {
            banner = Banner(kind: .error, message: error.localizedDescription)
        }
        refresh()
    }

    private func restoreBackup(agent: HookInstaller.Agent, refresh: @escaping () -> Void) {
        isWorking = true
        defer { isWorking = false }
        do {
            let path = try HookInstaller.restoreLatestBackup(for: agent)
            banner = Banner(kind: .success, message: "Restored the most recent backup to \(path).")
        } catch {
            banner = Banner(kind: .error, message: error.localizedDescription)
        }
        refresh()
    }

    private func sendTest(for agent: HookInstaller.Agent) {
        agentStatus.injectTest(agent: agent.rawValue, status: .wait, message: "Test: \(agent.displayName) is asking for input")
        banner = Banner(kind: .info, message: "Test event delivered. Check your menu bar and notification banners.")
    }

    // MARK: - MCP actions

    private func performMCPSetup(agent: MCPInstaller.Agent) {
        isWorking = true
        defer { isWorking = false }
        do {
            let backup = try MCPInstaller.install(agent)
            let extra = backup.map { " Backed up previous config to \($0.lastPathComponent)." } ?? ""
            banner = Banner(kind: .success, message: "\(agent.displayName) is now connected via MCP.\(extra) Restart the agent to pick up the change.")
        } catch {
            banner = Banner(kind: .error, message: "\(agent.displayName): \(error.localizedDescription)")
        }
        refreshAll()
    }

    private func performMCPUninstall(agent: MCPInstaller.Agent) {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try MCPInstaller.uninstall(agent)
            banner = Banner(kind: .info, message: "Removed DoomCoder from \(agent.displayName). A backup was saved.")
        } catch {
            banner = Banner(kind: .error, message: "\(agent.displayName): \(error.localizedDescription)")
        }
        refreshAll()
    }

    private func performMCPRestore(agent: MCPInstaller.Agent) {
        isWorking = true
        defer { isWorking = false }
        do {
            if let restored = try MCPInstaller.restoreLatestBackup(agent) {
                banner = Banner(kind: .success, message: "Restored backup from \(restored.lastPathComponent).")
            } else {
                banner = Banner(kind: .info, message: "No backup available for \(agent.displayName).")
            }
        } catch {
            banner = Banner(kind: .error, message: "\(agent.displayName): \(error.localizedDescription)")
        }
        refreshAll()
    }

    private func sendMCPTest(for agent: MCPInstaller.Agent) {
        agentStatus.injectTest(agent: agent.catalogId, status: .wait, message: "Test: \(agent.displayName) is asking for input")
        banner = Banner(kind: .info, message: "Test event delivered. Check your menu bar and notification banners.")
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
