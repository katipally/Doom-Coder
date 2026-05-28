// AgentListView.swift — DoomCoder Companion
// Main view showing configured agents (read-only, matches Mac TrackAgentsPopover)

import SwiftUI
import DoomCoderCore

struct AgentListView: View {
    @State private var agentStore = AgentListStore.shared
    @State private var macStore = MacStatusStore.shared
    @State private var engine = CompanionSyncEngine.shared
    
    var body: some View {
        List {
            if agentStore.agents.isEmpty {
                if engine.firstFetchCompleted {
                    EmptyStateView()
                } else {
                    HStack {
                        Spacer()
                        ProgressView("Syncing with Mac...")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 40)
                }
            } else {
                // Only show agents that are BOTH configured (installed) AND have toggle ON.
                // If installedAgents is empty we haven't loaded yet — show all toggle-ON agents.
                let visibleAgents: [TrackedAgent] = agentStore.installedAgents.isEmpty
                    ? agentStore.agents
                    : agentStore.agents.filter { agentStore.installedAgents.contains($0) }

                if visibleAgents.isEmpty {
                    EmptyStateView()
                } else {
                    Section {
                        ForEach(visibleAgents, id: \.rawValue) { agent in
                            NavigationLink {
                                AgentLogsView(agent: agent)
                            } label: {
                                AgentRow(
                                    agent: agent,
                                    status: agentStore.statuses[agent],
                                    isInstalled: true
                                )
                            }
                        }
                    } header: {
                        if let mac = macStore.primary {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(mac.name)
                                Spacer()
                                Text(relativeTime(mac.lastSeen))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .refreshable {
            await CompanionSyncEngine.shared.fetchChanges()
        }
        .navigationTitle("Agents")
    }
    
    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}

struct AgentRow: View {
    let agent: TrackedAgent
    let status: String?
    let isInstalled: Bool

    init(agent: TrackedAgent, status: String? = nil, isInstalled: Bool = true) {
        self.agent = agent
        self.status = status
        self.isInstalled = isInstalled
    }

    var body: some View {
        HStack(spacing: 12) {
            AgentIcon(agent: agent, size: 32)
                .opacity(isInstalled ? 1.0 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(.body.weight(.medium))
                    if !isInstalled {
                        Text("not installed")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 5) {
                    if let status, !status.isEmpty {
                        Circle()
                            .fill(statusColor(for: status))
                            .frame(width: 7, height: 7)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if agent.isIDEAgent {
                        Text("IDE")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func statusColor(for status: String) -> Color {
        switch status {
        case "running":              return .green
        case "waiting for approval": return .orange
        case "waiting for input":    return .yellow
        case "completed":            return .blue
        case "failed":               return .red
        case "idle", "open":         return .gray
        default:                     return .secondary
        }
    }
}

struct AgentIcon: View {
    let agent: TrackedAgent
    let size: CGFloat
    
    var body: some View {
        Group {
            // Try bundled imageset first
            if let _ = UIImage(named: agent.bundledAssetName) {
                Image(agent.bundledAssetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let url = AppGroupCache.iconURL(slug: agent.iconSlug),
                      let uiImage = UIImage(contentsOfFile: url.path) {
                // Try AppGroupCache (NSE-shared icon)
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // SF Symbol fallback
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}
