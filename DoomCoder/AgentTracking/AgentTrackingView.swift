import SwiftUI

// MARK: - AgentTrackingSelection
//
// A single enum driving the detail pane. Bound to the NavigationSplitView
// sidebar so selection is always in sync with what's showing.

enum AgentTrackingSelection: Hashable {
    case liveSession(String)              // AgentSession.id
    case agent(String)                    // AgentCatalog.Info.id
    case channel(ChannelKind)
    case system(SystemKind)

    enum ChannelKind: String, Hashable, CaseIterable {
        case reminder, imessage, ntfy

        var displayName: String {
            switch self {
            case .reminder: return "Reminders (iCloud)"
            case .imessage: return "iMessage"
            case .ntfy:     return "ntfy.sh"
            }
        }

        var icon: String {
            switch self {
            case .reminder: return "checklist"
            case .imessage: return "message.fill"
            case .ntfy:     return "bell.badge.fill"
            }
        }
    }

    enum SystemKind: String, Hashable, CaseIterable {
        case focus, icloud, deliveryLog

        var displayName: String {
            switch self {
            case .focus:        return "Focus Filter"
            case .icloud:       return "iCloud Round-Trip"
            case .deliveryLog:  return "Delivery Log"
            }
        }

        var icon: String {
            switch self {
            case .focus:       return "moon.circle.fill"
            case .icloud:      return "icloud.fill"
            case .deliveryLog: return "tray.full.fill"
            }
        }
    }
}

// MARK: - AgentTrackingView
//
// The primary v1.0 surface. A three-pane NavigationSplitView that shows:
//   • Live sessions (top) — what's happening right now
//   • Agents — every supported agent with install status + setup launcher
//   • iPhone channels — Reminders / iMessage / ntfy with setup + test
//   • System — Focus filter, iCloud round-trip, delivery log
// The detail pane is driven by a single selection enum.

struct AgentTrackingView: View {
    @Bindable var agentStatus: AgentStatusManager
    @Bindable var iPhoneRelay: IPhoneRelay
    @Bindable var focusManager: FocusFilterManager
    var socketServer: SocketServer

    @State private var selection: AgentTrackingSelection? = .system(.deliveryLog)
    @State private var agentSetupSheet: String? = nil
    @State private var channelSetupSheet: AgentTrackingSelection.ChannelKind? = nil

    var body: some View {
        NavigationSplitView {
            AgentTrackingSidebar(
                agentStatus: agentStatus,
                iPhoneRelay: iPhoneRelay,
                focusManager: focusManager,
                selection: $selection
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            Group {
                switch selection {
                case .liveSession(let id):
                    if let session = agentStatus.sessions.first(where: { $0.id == id }) {
                        SessionDetailPane(session: session, iPhoneRelay: iPhoneRelay)
                    } else {
                        EmptyDetailPane(
                            icon: "bolt.slash",
                            title: "Session ended",
                            message: "This session has finished. Select another row from the sidebar."
                        )
                    }
                case .agent(let id):
                    AgentDetailPane(
                        agentId: id,
                        iPhoneRelay: iPhoneRelay,
                        agentStatus: agentStatus,
                        openSetup: { agentSetupSheet = id }
                    )
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
                        focusManager: focusManager,
                        socketServer: socketServer
                    )
                case .none:
                    EmptyDetailPane(
                        icon: "sidebar.left",
                        title: "Select something from the sidebar",
                        message: "Live sessions show up at the top as they start. Agents, iPhone channels, and system diagnostics are below."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("Agent Tracking")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(systemName: agentStatus.isAnyAgentActive ? "bolt.circle.fill" : "bolt.slash.circle")
                        .foregroundStyle(agentStatus.isAnyAgentActive ? .green : .secondary)
                    Text(agentStatus.isAnyAgentActive
                         ? "\(agentStatus.sessions.count) live"
                         : "Idle")
                        .font(.headline)
                }
            }
        }
        .sheet(item: Binding(
            get: { agentSetupSheet.map { AgentSheetID(id: $0) } },
            set: { agentSetupSheet = $0?.id }
        )) { wrapper in
            AgentSetupSheet(agentId: wrapper.id) {
                agentSetupSheet = nil
            }
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
