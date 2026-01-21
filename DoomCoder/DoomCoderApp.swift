import SwiftUI
import ServiceManagement

@main
struct DoomCoderApp: App {
    @State private var sleepManager = SleepManager()
    @State private var updaterViewModel = CheckForUpdatesViewModel()
    @State private var agentStatus = AgentStatusManager()
    @State private var socketServer = SocketServer()
    @State private var iPhoneRelay = IPhoneRelay()
    @State private var focusManager = FocusFilterManager()

    init() {
        // One-shot cleanup of v0.x UserDefaults keys that no longer exist.
        LegacyDefaults.migrate()
        // Eagerly deploy both the hook runner AND the MCP server so they're
        // always up to date before any agent touches them. Silent on failure —
        // Agent Tracking surfaces any problem via per-agent status badges.
        try? HookRuntime.deploy()
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

        Window("Agent Tracking", id: "agent-tracking") {
            AgentTrackingView(
                agentStatus: agentStatus,
                iPhoneRelay: iPhoneRelay,
                focusManager: focusManager,
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
    }

    // MARK: - Agent bridge wiring
    //
    // Runs exactly once on first MenuBarExtra render. We start the Unix-socket
    // listener, forward every parsed event to AgentStatusManager, and fan
    // meaningful state changes out to NotificationManager + IPhoneRelay.
    private func wireAgentBridge() {
        guard !socketServer.isRunning else { return }

        socketServer.onEvent = { event in
            agentStatus.ingest(event)
        }

        agentStatus.onSessionUpdated = { session, event in
            NotificationManager.shared.fire(event: event, session: session)
            iPhoneRelay.fire(event: event, session: session)
        }

        agentStatus.onActivityChanged = { active in
            focusManager.reflect(active: active)
        }

        // Wire the synthetic "verify setup" action fired by AgentSetupSheet
        // into the real pipeline so the user sees end-to-end delivery.
        NotificationCenter.default.addObserver(
            forName: .dcVerifySetup,
            object: nil,
            queue: .main
        ) { note in
            let agentId = (note.userInfo?["agent"] as? String) ?? "claude-code"
            Task { @MainActor in
                agentStatus.injectTest(agent: agentId, status: .wait, message: "DoomCoder setup verification")
            }
        }

        _ = socketServer.start()

        // Opportunistic cleanup of old DoomCoder reminders on each launch.
        // Best-effort: silent on permission denial.
        Task.detached { [iPhoneRelay] in
            await iPhoneRelay.reminder.cleanupDeliveredReminders()
        }
    }
}
