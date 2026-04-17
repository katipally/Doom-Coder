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
            // LIVE SESSIONS ----------------------------------------------
            if !agentStatus.sessions.isEmpty {
                Section("Live Sessions") {
                    ForEach(agentStatus.sessions.sorted(by: { $0.lastEventAt > $1.lastEventAt })) { s in
                        NavigationLink(value: AgentTrackingSelection.liveSession(s.id)) {
                            LiveSessionRow(session: s)
                        }
                    }
                }
            }

            // AGENTS -----------------------------------------------------
            Section("Agents") {
                ForEach(AgentCatalog.all, id: \.id) { info in
                    NavigationLink(value: AgentTrackingSelection.agent(info.id)) {
                        AgentRow(info: info)
                    }
                }
            }

            // iPHONE CHANNELS --------------------------------------------
            Section("iPhone Channels") {
                ForEach(AgentTrackingSelection.ChannelKind.allCases, id: \.self) { kind in
                    NavigationLink(value: AgentTrackingSelection.channel(kind)) {
                        ChannelRow(kind: kind, relay: iPhoneRelay)
                    }
                }
            }

            // SYSTEM -----------------------------------------------------
            Section("System") {
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

private struct LiveSessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName).font(.body)
                Text(rowSubtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var badge: StatusBadge {
        switch session.state {
        case .active:   return StatusBadge(.live)
        case .waiting:  return StatusBadge(.warn)
        case .errored:  return StatusBadge(.error)
        case .done:     return StatusBadge(.ready)
        }
    }

    private var rowSubtitle: String {
        let repo = session.repoName.map { "\($0) · " } ?? ""
        let state: String
        switch session.state {
        case .active:   state = "Working"
        case .waiting:  state = "Needs input"
        case .errored:  state = "Error"
        case .done:     state = "Done"
        }
        return "\(repo)\(state) · \(session.elapsedText)"
    }
}

private struct AgentRow: View {
    let info: AgentCatalog.Info

    var body: some View {
        HStack(spacing: 10) {
            installBadge
            Text(info.displayName)
            Spacer()
            Text(info.tier == .hook ? "Hook" : "MCP")
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
        if info.tier == .hook {
            if let hook = HookInstaller.Agent(rawValue: info.id) {
                switch HookInstaller.status(for: hook) {
                case .installed:                return StatusBadge(.ready)
                case .partial:                  return StatusBadge(.warn)
                case .notInstalled:             return StatusBadge(.off)
                case .missingHookScript:        return StatusBadge(.error)
                }
            }
            return StatusBadge(.off)
        } else {
            if let mcp = Self.mcpAgent(for: info.id) {
                switch MCPInstaller.status(for: mcp) {
                case .installed:               return StatusBadge(.ready)
                case .modified:                return StatusBadge(.warn)
                case .notInstalled:            return StatusBadge(.off)
                case .missingConfig:           return StatusBadge(.error)
                }
            }
            return StatusBadge(.off)
        }
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
        case .ntfy: return "ntfy"
        }
    }

    private var isActive: Bool {
        relay.activeChannel?.info.id == channelID
    }

    private var badge: StatusBadge {
        switch kind {
        case .ntfy: return relay.ntfy.isReady ? StatusBadge(.ready) : StatusBadge(.off)
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
