// DashboardView.swift — DoomCoder Companion
// The Mac-dependent tab. Shows the read-only mirror of the Mac: agent list
// and per-agent notification log. No controls, no connect flow, no pairing —
// data simply appears when the Mac publishes it.

import SwiftUI
import DoomCoderCore

struct DashboardView: View {
    @State private var agentStore = AgentListStore.shared
    @State private var engine = CompanionSyncEngine.shared

    var body: some View {
        List {
            if agentStore.agents.isEmpty {
                if engine.firstFetchCompleted {
                    Section {
                        ContentUnavailableView(
                            "No Agents Yet",
                            systemImage: "macbook.and.iphone",
                            description: Text("Agents on your Mac will appear here automatically once DoomCoder is running on the Mac.")
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Syncing with Mac…")
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                        .padding(.vertical, 40)
                    }
                }
            } else {
                let visibleAgents: [TrackedAgent] = agentStore.installedAgents.isEmpty
                    ? agentStore.agents
                    : agentStore.agents.filter { agentStore.installedAgents.contains($0) }

                if visibleAgents.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Agents Yet",
                            systemImage: "macbook.and.iphone",
                            description: Text("Agents on your Mac will appear here automatically once DoomCoder is running on the Mac.")
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(visibleAgents, id: \.rawValue) { agent in
                            NavigationLink(value: agent) {
                                AgentRow(
                                    agent: agent,
                                    status: agentStore.statuses[agent],
                                    isInstalled: true
                                )
                            }
                        }
                    } header: {
                        Text("Agents")
                    }
                }
            }
        }
        .navigationTitle("Dashboard")
        .refreshable {
            await CompanionSyncEngine.shared.forceFetchAll()
        }
    }
}
