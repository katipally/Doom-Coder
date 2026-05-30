// DashboardView.swift — DoomCoder Companion
// The optional, Mac-dependent tab. Clearly labeled so users understand the Tools
// tab works without a Mac and this one adds live monitoring + remote control when
// the free DoomCoder Mac app is connected.
//
//   • Connected:     live agents (AgentList) + keep-awake remote control.
//   • Not connected: a clear explainer that this needs the Mac app, plus Connect,
//                    the interactive demo, and the Mac download.

import SwiftUI
import DoomCoderCore

struct DashboardView: View {
    @State private var macStore = MacStatusStore.shared
    @State private var agentStore = AgentListStore.shared
    @State private var showConnect = false

    private let downloadURL = URL(string: "https://github.com/katipally/Doom-Coder/releases")!

    var body: some View {
        Group {
            if macStore.primary != nil {
                connected
            } else {
                notConnected
            }
        }
        .navigationTitle("Dashboard")
        .sheet(isPresented: $showConnect) {
            ConnectFlowView(onFinished: {})
        }
    }

    // MARK: - Connected

    private var connected: some View {
        List {
            Section {
                MacReachabilityBanner()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                MacControlView()
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            agentsSection
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await CompanionSyncEngine.shared.forceFetchAll()
        }
    }

    @ViewBuilder
    private var agentsSection: some View {
        let agents = visibleAgents
        Section {
            if agents.isEmpty {
                Text("No agent activity yet. Agents appear here as they run on your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ForEach(agents, id: \.rawValue) { agent in
                    NavigationLink(value: agent) {
                        AgentRow(
                            agent: agent,
                            status: agentStore.statuses[agent],
                            isInstalled: true
                        )
                    }
                }
            }
        } header: {
            Text("Agents")
        }
    }

    private var visibleAgents: [TrackedAgent] {
        agentStore.installedAgents.isEmpty
            ? agentStore.agents
            : agentStore.agents.filter { agentStore.installedAgents.contains($0) }
    }

    // MARK: - Not connected

    private var notConnected: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 16) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("Connect your Mac")
                            .font(.title2.bold())
                        Text("The Dashboard monitors the AI coding agents running on your Mac and lets you control keep-awake remotely. It needs the free DoomCoder Mac app.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        Haptics.tap()
                        showConnect = true
                    } label: {
                        Label("Connect", systemImage: "link")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    NavigationLink {
                        DemoView()
                    } label: {
                        Label("Try the interactive demo", systemImage: "play.circle")
                            .font(.subheadline.weight(.medium))
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                noMacReminder

                Link(destination: downloadURL) {
                    Label("Download DoomCoder for Mac", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var noMacReminder: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("No Mac? No problem.")
                    .font(.subheadline.weight(.semibold))
                Text("The Tools tab — the AI prompt composer and smart notes — works fully on this device without connecting anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
