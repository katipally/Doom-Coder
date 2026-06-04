// DashboardView.swift — DoomCoder Companion
// The Mac-dependent tab. Shows the read-only mirror of the Mac: agent list
// and per-agent notification log. v2.7 adds a Devices section above the
// agent list, a per-Mac switcher when more than one Mac is paired, and a
// "Add a Mac" entry point in the empty state.
//
// v2.7 fix: agents are only visible when at least one Connection exists.
// This prevents ghost agents from showing up before the user has paired
// (e.g. on a fresh install, or after a user explicitly removes all Macs).

import SwiftUI
import DoomCoderCore

struct DashboardView: View {
    @State private var agentStore = AgentListStore.shared
    @State private var engine = CompanionSyncEngine.shared
    @State private var connectionStore = ConnectionStore.shared
    @State private var selectedMacId: String?

    /// True when at least one active Connection exists. Drives the
    /// "show agents" vs "Add a Mac" decision.
    private var hasActiveConnection: Bool {
        !connectionStore.connections.isEmpty
    }

    var body: some View {
        List {
            DevicesSection(selectedMacId: $selectedMacId)

            if connectionStore.connections.count > 1 {
                Section {
                    MacSwitcher(connections: connectionStore.connections, selectedMacId: $selectedMacId)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            // v2.7 invariant: no Connection → no agents. The user sees the
            // "Add a Mac" empty state until they pair (or, for same-Apple-ID
            // users, the implicit connection auto-registers when the first
            // MacStatus record arrives).
            if !hasActiveConnection {
                Section {
                    DashboardEmptyView()
                }
            } else if agentStore.agents.isEmpty {
                if engine.firstFetchCompleted {
                    Section {
                        DashboardEmptyView()
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
                let visibleAgents: [TrackedAgent] = filteredAgents

                if visibleAgents.isEmpty {
                    Section {
                        DashboardEmptyView()
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

    /// Apply the per-Mac filter if a Mac is selected. v2.7 only filters the
    /// display, not the push path (broadcast remains global).
    private var filteredAgents: [TrackedAgent] {
        // 1. Pick the agent set: per-Mac if a Mac is selected and we have
        //    that Mac's snapshot, otherwise the union across all known Macs.
        let perMacAgents: [TrackedAgent] = {
            if let selectedMacId, let scoped = agentStore.agentsByMacId[selectedMacId] {
                return scoped
            }
            return agentStore.agents
        }()
        // 2. Apply the installed-agent filter if any are known.
        return agentStore.installedAgents.isEmpty
            ? perMacAgents
            : perMacAgents.filter { agentStore.installedAgents.contains($0) }
    }
}
