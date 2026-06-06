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
        .toolbar {
            if !macStore.byMacId.isEmpty {
                ToolbarItem(placement: .topBarLeading) { macSwitcher }
            }
        }
        .sheet(isPresented: $showConnect) {
            ConnectFlowView(onFinished: {})
        }
    }

    // MARK: - Mac switcher (multiple Macs, one active at a time)

    private var sortedMacs: [MacStatusRecord] {
        macStore.byMacId.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Top-of-Dashboard dropdown to switch the active Mac (iOS 26 HIG `Menu`).
    /// Only one Mac is active at a time; the selection persists. Each Mac has a
    /// submenu to switch to it or disconnect it (keeping the others).
    private var macSwitcher: some View {
        Menu {
            ForEach(sortedMacs, id: \.macId) { mac in
                let isActive = mac.macId == macStore.primary?.macId
                Menu {
                    Button {
                        macStore.setPrimary(mac.macId); Haptics.tap()
                    } label: { Label("Switch to this Mac", systemImage: "checkmark.circle") }
                    Button(role: .destructive) {
                        disconnect(mac)
                    } label: { Label("Disconnect", systemImage: "minus.circle") }
                } label: {
                    Label(isActive ? "\(mac.name) (active)" : mac.name,
                          systemImage: isActive ? "checkmark" : "desktopcomputer")
                }
            }
            Divider()
            Button { Haptics.tap(); showConnect = true } label: {
                Label("Add Device…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "desktopcomputer")
                Text(macStore.primary?.name ?? "Macs")
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel("Switch Mac. Current: \(macStore.primary?.name ?? "none")")
    }

    /// Disconnects a single Mac: leaves its share (cross-account) or forgets it
    /// (same-account), and clears its cached agent state. Other Macs are kept.
    private func disconnect(_ mac: MacStatusRecord) {
        Haptics.tap()
        Task {
            await CompanionSyncEngine.shared.leaveShare(forMacId: mac.macId)
            MacStatusStore.shared.remove(macId: mac.macId)
            AgentListStore.shared.clear(macId: mac.macId)
            Haptics.success()
        }
    }

    // MARK: - Connected

    private var connected: some View {
        List {
            MacControlView()

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
                        Label("Add Device", systemImage: "plus")
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
