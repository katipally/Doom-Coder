import SwiftUI

// MARK: - AgentTrackingSidebar
//
// Four sections: LIVE SESSIONS, AGENTS, iPHONE CHANNELS, SYSTEM. Each row is
// a tappable selection bound to the parent's AgentTrackingSelection enum.
// Status badges are computed on the fly from the relevant manager/installer.

struct AgentTrackingSidebar: View {
    @Bindable var agentStatus: AgentStatusManager
    @Bindable var iPhoneRelay: IPhoneRelay
    @Binding var selection: AgentTrackingSelection?

    var body: some View {
        List(selection: $selection) {
            // AGENTS -----------------------------------------------------
            Section("Agents") {
                ForEach(AgentCatalog.all, id: \.id) { info in
                    NavigationLink(value: AgentTrackingSelection.agent(info.id)) {
                        AgentRow(info: info, agentStatus: agentStatus)
                    }
                }
                NavigationLink(value: AgentTrackingSelection.installAnywhere) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.square.on.square")
                            .foregroundStyle(.secondary)
                        Text("Install Anywhere")
                        Spacer()
                        Text("Any MCP")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background {
                                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                            }
                    }
                    .padding(.vertical, 1)
                }
            }

            // CHANNELS ---------------------------------------------------
            Section("Channels") {
                ForEach(AgentTrackingSelection.ChannelKind.allCases, id: \.self) { kind in
                    NavigationLink(value: AgentTrackingSelection.channel(kind)) {
                        ChannelRow(kind: kind, relay: iPhoneRelay)
                    }
                }
            }

            // DIAGNOSTICS ------------------------------------------------
            Section("Diagnostics") {
                ForEach(AgentTrackingSelection.SystemKind.allCases, id: \.self) { kind in
                    NavigationLink(value: AgentTrackingSelection.system(kind)) {
                        SystemRow(kind: kind, iPhoneRelay: iPhoneRelay)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Rows

private struct AgentRow: View {
    let info: AgentCatalog.Info
    @Bindable var agentStatus: AgentStatusManager

    var body: some View {
        HStack(spacing: 10) {
            installBadge
            Text(info.displayName)
            Spacer()
            // v1.8: per-agent Track toggle bound directly to watchedAgentIds.
            // Disabled (and dimmed) for unconfigured agents so the
            // affordance is still visible but clearly not yet usable.
            let configured = agentStatus.isAgentConfigured(info.id)
            let isTracked  = agentStatus.watchedAgentIds.contains(info.id)
            Button {
                if isTracked {
                    agentStatus.watchedAgentIds.remove(info.id)
                } else {
                    agentStatus.watchedAgentIds.insert(info.id)
                }
            } label: {
                Label(isTracked ? "Tracking" : "Track",
                      systemImage: isTracked ? "bell.fill" : "bell")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(!configured)
            .opacity(configured ? 1.0 : 0.35)
            .help(configured
                  ? (isTracked
                     ? "Tracking is ON — \(info.displayName) will fire notifications."
                     : "Tracking is OFF — notifications suppressed for \(info.displayName).")
                  : "Complete setup first — this agent hasn't been verified yet.")

            Text("MCP")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                }
        }
        .padding(.vertical, 1)
    }

    private var installBadge: StatusBadge {
        // Touch agentStatus.mcpHelloAt so this computed property re-runs
        // whenever a hello arrives — otherwise the sidebar is stuck on
        // .warn until the window is redrawn for an unrelated reason.
        _ = agentStatus.mcpHelloAt[info.id]
        if let mcp = Self.mcpAgent(for: info.id) {
            switch MCPInstaller.status(for: mcp) {
            case .live:                    return StatusBadge(.ready)
            case .configWritten:
                // Locally-known configured (sticky flag) — neutral instead
                // of ⚠︎. Only show warn when config is written but the
                // agent has never produced a hello anywhere.
                if agentStatus.isAgentConfigured(info.id) { return StatusBadge(.off) }
                return StatusBadge(.warn)
            case .modified:                return StatusBadge(.warn)
            case .notInstalled:            return StatusBadge(.off)
            case .missingConfig:           return StatusBadge(.error)
            }
        }
        return StatusBadge(.off)
    }

    static func mcpAgent(for catalogId: String) -> MCPInstaller.Agent? {
        MCPInstaller.Agent.allCases.first { $0.catalogId == catalogId }
    }
}

private struct ChannelRow: View {
    let kind: AgentTrackingSelection.ChannelKind
    let relay: IPhoneRelay

    var body: some View {
        HStack(spacing: 10) {
            badge
            Image(systemName: kind.icon).foregroundStyle(.secondary)
            Text(kind.displayName)
            Spacer()
            if isActive {
                Text("Active")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.12))
                    }
            }
        }
        .padding(.vertical, 1)
    }

    private var channelID: String {
        switch kind {
        case .inMac: return "inmac"
        case .ntfy:  return "ntfy"
        }
    }

    private var isActive: Bool {
        relay.activeChannel?.info.id == channelID
    }

    private var badge: StatusBadge {
        switch kind {
        case .inMac: return relay.inMac.isReady ? StatusBadge(.ready) : StatusBadge(.off)
        case .ntfy:  return relay.ntfy.isReady  ? StatusBadge(.ready) : StatusBadge(.off)
        }
    }
}

private struct SystemRow: View {
    let kind: AgentTrackingSelection.SystemKind
    let iPhoneRelay: IPhoneRelay

    var body: some View {
        HStack(spacing: 10) {
            badge
            Image(systemName: kind.icon).foregroundStyle(.secondary)
            Text(kind.displayName)
        }
        .padding(.vertical, 1)
    }

    private var badge: StatusBadge {
        switch kind {
        case .deliveryLog: return iPhoneRelay.deliveryLog.isEmpty ? StatusBadge(.off) : StatusBadge(.ready, "\(iPhoneRelay.deliveryLog.count)")
        }
    }
}
