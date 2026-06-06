// DashboardView.swift — DoomCoder Companion
// The Mac-dependent tab. Shows the read-only mirror of the Mac: agent list
// and per-agent notification log. v5.3: agents are always visible; the
// devices section header reads "No devices" when the user has no
// connections, with an inline "Add a Mac" button (see DevicesSection).
// This replaces the v2.7 "no Connection → hide agents" behaviour, which
// the audit flagged as wrong: users with a freshly-paired-then-
// disconnected Mac saw a blank Agents tab with no affordance to pair.

import SwiftUI
import DoomCoderCore

struct DashboardView: View {
    @State private var agentStore = AgentListStore.shared
    @State private var engine = CompanionSyncEngine.shared
    @State private var connectionStore = ConnectionStore.shared
    @State private var router = AppRouter.shared

    var body: some View {
        List {
            if connectionStore.hasInactiveConnection {
                StaleConnectionBanner(store: connectionStore)
            }

            DevicesSection(selectedMacId: $router.selectedMacId)

            if connectionStore.connections.count > 1 {
                Section {
                    MacSwitcher(connections: connectionStore.connections, selectedMacId: $router.selectedMacId)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            // v5.3: Agents section is always present. When the
            // user has no paired Mac the list is empty, but the
            // user can still see the section header and the
            // Devices section's "Add a Mac" CTA above.
            if agentStore.agents.isEmpty {
                if engine.firstFetchCompleted || !connectionStore.connections.isEmpty {
                    Section {
                        DashboardEmptyView()
                    } header: {
                        Text("Agents")
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
                    } header: {
                        Text("Agents")
                    }
                }
            } else {
                let visibleAgents: [TrackedAgent] = filteredAgents

                if visibleAgents.isEmpty {
                    Section {
                        DashboardEmptyView()
                    } header: {
                        Text("Agents")
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
        // 0. Manual-only gate: only show agents for Macs we're ACTIVELY paired
        //    with. The on-disk agent cache (loaded at launch) and same-iCloud
        //    AgentConfig records must never surface a Mac the user hasn't paired.
        let activeMacIds = Set(connectionStore.connections
            .filter { $0.status == .active }
            .map { $0.macDeviceId })
        guard !activeMacIds.isEmpty else { return [] }

        // 1. Pick the agent set: per-Mac if a Mac is selected and we have
        //    that Mac's snapshot, otherwise the union across all known Macs.
        let perMacAgents: [TrackedAgent] = {
            if let selectedMacId = router.selectedMacId,
               activeMacIds.contains(selectedMacId),
               let scoped = agentStore.agentsByMacId[selectedMacId] {
                return scoped
            }
            // Union across active Macs we have a snapshot for; fall back to the
            // flat list only when at least one Mac is actively paired.
            let scoped = activeMacIds.compactMap { agentStore.agentsByMacId[$0] }.flatMap { $0 }
            return scoped.isEmpty ? agentStore.agents : Array(Set(scoped))
        }()
        // 2. Apply the installed-agent filter if any are known.
        return agentStore.installedAgents.isEmpty
            ? perMacAgents
            : perMacAgents.filter { agentStore.installedAgents.contains($0) }
    }
}
