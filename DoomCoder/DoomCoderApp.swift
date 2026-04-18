import SwiftUI
import ServiceManagement

@main
struct DoomCoderApp: App {
    @State private var sleepManager = SleepManager()
    @State private var updaterViewModel = CheckForUpdatesViewModel()
    @State private var agentStatus = AgentStatusManager()
    @State private var socketServer = SocketServer()
    @State private var iPhoneRelay = IPhoneRelay()
    // scenePhase no longer observed — v1.1.1 removed the calendar cleanup hook
    // that used it. Kept here as a reminder in case a future scene lifecycle
    // callback is needed.

    init() {
        // One-shot cleanup of legacy UserDefaults keys that no longer exist
        // (includes the v1.7→v1.8 watchTarget → watchedAgentIds migration and
        // the Full Mode → Screen On rename).
        LegacyDefaults.migrate()
        // Eagerly deploy the MCP server script so it's always current before
        // any agent touches it. Silent on failure — Agent Tracking surfaces
        // problems via per-agent status badges.
        try? MCPRuntime.deploy()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                sleepManager: sleepManager,
                updaterViewModel: updaterViewModel,
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

        Window("Configure Agents", id: "configure") {
            AgentTrackingView(
                agentStatus: agentStatus,
                iPhoneRelay: iPhoneRelay,
                socketServer: socketServer
            )
        }
        .defaultSize(width: 960, height: 640)

        Window("Settings", id: "settings") {
            SettingsView(
                sleepManager: sleepManager,
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

        Window("Welcome to DoomCoder", id: "onboarding") {
            OnboardingView(sleepManager: sleepManager) {
                NSApplication.shared.keyWindow?.close()
            }
        }
        .windowResizability(.contentSize)

        Window("Doctor", id: "doomcoder-doctor") {
            DoomCoderDoctor(
                agentStatus: agentStatus,
                iPhoneRelay: iPhoneRelay,
                socketServer: socketServer
            )
        }
        .defaultSize(width: 820, height: 640)
    }

    private func wireAgentBridge() {
        guard !socketServer.isRunning else { return }

        socketServer.onEvent = { event in
            agentStatus.ingest(event)
        }

        agentStatus.onSessionUpdated = { session, event in
            NotificationManager.shared.fire(event: event, session: session)
            iPhoneRelay.fire(event: event, session: session)
        }

        // Wire the notification "End session" action back to the manager.
        NotificationManager.shared.onEndSession = { sid in
            agentStatus.endSession(id: sid)
        }

        _ = socketServer.start()
    }
}
