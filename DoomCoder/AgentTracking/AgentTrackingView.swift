import SwiftUI

// MARK: - AgentTrackingSelection
//
// A single enum driving the detail pane. Bound to the NavigationSplitView
// sidebar so selection is always in sync with what's showing.

enum AgentTrackingSelection: Hashable {
    case agent(String)                    // AgentCatalog.Info.id
    case installAnywhere
    case channel(ChannelKind)
    case system(SystemKind)

    enum ChannelKind: String, Hashable, CaseIterable {
        case ntfy

        var displayName: String {
            switch self {
            case .ntfy: return "ntfy.sh"
            }
        }

        var icon: String {
            switch self {
            case .ntfy: return "bell.badge.fill"
            }
        }
    }

    enum SystemKind: String, Hashable, CaseIterable {
        case deliveryLog

        var displayName: String {
            switch self {
            case .deliveryLog:  return "Delivery Log"
            }
        }

        var icon: String {
            switch self {
            case .deliveryLog: return "tray.full.fill"
            }
        }
    }
}

// MARK: - AgentTrackingView
//
// The primary v1.5 Configure surface. A two-pane NavigationSplitView focused
// strictly on setup:
//   • Agents — every supported agent with install status + setup launcher
//   • Channels — ntfy.sh setup & test
//   • Diagnostics — Delivery Log
// Live session rows were removed in v1.5 — live status is surfaced through
// the menubar Track submenu, not duplicated in this window.

struct AgentTrackingView: View {
    @Bindable var agentStatus: AgentStatusManager
    @Bindable var iPhoneRelay: IPhoneRelay
    var socketServer: SocketServer

    @State private var selection: AgentTrackingSelection? = .system(.deliveryLog)
    @State private var agentSetupSheet: String? = nil
    @State private var channelSetupSheet: AgentTrackingSelection.ChannelKind? = nil

    var body: some View {
        NavigationSplitView {
            AgentTrackingSidebar(
                agentStatus: agentStatus,
                iPhoneRelay: iPhoneRelay,
                selection: $selection
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            Group {
                switch selection {
                case .agent(let id):
                    AgentDetailPane(
                        agentId: id,
                        iPhoneRelay: iPhoneRelay,
                        agentStatus: agentStatus,
                        openSetup: { agentSetupSheet = id }
                    )
                case .installAnywhere:
                    InstallAnywherePane(agentStatus: agentStatus)
                case .channel(let kind):
                    ChannelDetailPane(
                        kind: kind,
                        iPhoneRelay: iPhoneRelay,
                        openSetup: { channelSetupSheet = kind }
                    )
                case .system(let kind):
                    SystemDetailPane(
                        kind: kind,
                        iPhoneRelay: iPhoneRelay,
                        socketServer: socketServer
                    )
                case .none:
                    EmptyDetailPane(
                        icon: "sidebar.left",
                        title: "Select something from the sidebar",
                        message: "Configure agents and channels here. Live status is available from the menubar's Track submenu."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("Configure Agents")
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: agentStatus.isAnyAgentActive
                          ? "bolt.circle.fill"
                          : "moon.zzz.fill")
                        .foregroundStyle(agentStatus.isAnyAgentActive ? .green : .secondary)
                        .symbolEffect(.pulse, options: .repeating, isActive: agentStatus.isAnyAgentActive)
                    Text(agentStatus.isAnyAgentActive
                         ? "\(agentStatus.sessions.count) live session\(agentStatus.sessions.count == 1 ? "" : "s")"
                         : "Idle — waiting for agent activity")
                        .font(.subheadline)
                        .foregroundStyle(agentStatus.isAnyAgentActive ? .primary : .secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(.regularMaterial)
                )
            }
        }
        .sheet(item: Binding(
            get: { agentSetupSheet.map { AgentSheetID(id: $0) } },
            set: { agentSetupSheet = $0?.id }
        )) { wrapper in
            AgentSetupSheet(agentId: wrapper.id, onDone: {
                agentSetupSheet = nil
            }, agentStatus: agentStatus)
        }
        .sheet(item: $channelSetupSheet) { kind in
            ChannelSetupSheet(kind: kind, relay: iPhoneRelay) {
                channelSetupSheet = nil
            }
        }
    }
}

// Identifiable wrapper so the sheet can use a plain String id.
private struct AgentSheetID: Identifiable {
    let id: String
}

extension AgentTrackingSelection.ChannelKind: Identifiable {
    var id: String { rawValue }
}

// MARK: - EmptyDetailPane

struct EmptyDetailPane: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.title3).foregroundStyle(.secondary)
            Text(message)
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
