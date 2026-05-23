// AgentListView.swift — DoomCoder Companion
// Main view showing configured agents (read-only, matches Mac TrackAgentsPopover)

import SwiftUI
import DoomCoderCore

struct AgentListView: View {
    @State private var agentStore = AgentListStore.shared
    @State private var macStore = MacStatusStore.shared
    @State private var engine = CompanionSyncEngine.shared
    
    var body: some View {
        Group {
            if agentStore.agents.isEmpty {
                if engine.firstFetchCompleted {
                    EmptyStateView()
                } else {
                    ProgressView("Syncing with Mac...")
                }
            } else {
                List {
                    Section {
                        ForEach(agentStore.agents, id: \.rawValue) { agent in
                            NavigationLink {
                                AgentLogsView(agent: agent)
                            } label: {
                                AgentRow(agent: agent)
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
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
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
    
    var body: some View {
        HStack(spacing: 12) {
            AgentIcon(agent: agent, size: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .font(.body.weight(.medium))
                
                if agent.isIDEAgent {
                    Text("IDE")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct AgentIcon: View {
    let agent: TrackedAgent
    let size: CGFloat
    
    var body: some View {
        Group {
            // Try bundled imageset first
            if let _ = UIImage(named: "agent-\(agent.iconSlug)") {
                Image("agent-\(agent.iconSlug)")
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
