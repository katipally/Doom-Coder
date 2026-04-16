import SwiftUI
import ServiceManagement

@main
struct DoomCoderApp: App {
    @State private var sleepManager = SleepManager()
    @State private var updaterViewModel = CheckForUpdatesViewModel()
    @State private var appDetector = AppDetector()
    @State private var agentStatus = AgentStatusManager()
    @State private var socketServer = SocketServer()
    @State private var iPhoneRelay = IPhoneRelay()

    init() {
        // Eagerly deploy both the hook runner AND the MCP server so they're
        // always up to date before any agent touches them. Silent on failure —
        // the Settings UI surfaces any problem via per-agent status badges.
        try? HookRuntime.deploy()
        try? MCPRuntime.deploy()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                sleepManager: sleepManager,
                updaterViewModel: updaterViewModel,
                appDetector: appDetector,
                agentStatus: agentStatus
            )
            .task { wireAgentBridge() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: sleepManager.isActive ? "bolt.fill" : "bolt.slash.fill")
                    .symbolRenderingMode(.monochrome)
                if agentStatus.isAnyAgentActive {
                    Text("\(agentStatus.sessions.count)")
                        .font(.caption2.monospacedDigit())
                }
            }
        }

        Window("Active Apps", id: "active-apps") {
            ActiveAppsView(appDetector: appDetector, sleepManager: sleepManager)
        }
        .windowResizability(.contentSize)

        Window("Settings", id: "settings") {
            SettingsView(
                sleepManager: sleepManager,
                appDetector: appDetector,
                agentStatus: agentStatus,
                socketServer: socketServer,
                iPhoneRelay: iPhoneRelay
            )
        }
        .windowResizability(.contentSize)

        Window("About Doom Coder", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }

    // MARK: - Agent bridge wiring
    //
    // Runs exactly once on first MenuBarExtra render. We start the Unix-socket
    // listener, forward every parsed event to AgentStatusManager, and fan
    // meaningful state changes out to NotificationManager for macOS banners.
    private func wireAgentBridge() {
        guard !socketServer.isRunning else { return }

        socketServer.onEvent = { event in
            agentStatus.ingest(event)
        }

        agentStatus.onSessionUpdated = { session, event in
            NotificationManager.shared.fire(event: event, session: session)
            iPhoneRelay.fire(event: event, session: session)
        }

        // Tier-3 demotion: silence the heuristic notifier whenever the Agent
        // Bridge has a live, authoritative session running. The bridge path
        // already fires richer, deterministic banners via NotificationManager.fire.
        NotificationManager.shared.shouldSuppressHeuristic = {
            agentStatus.isAnyAgentActive
        }

        _ = socketServer.start()
    }
}


