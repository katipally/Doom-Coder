import SwiftUI
import AppKit

@main
struct DoomCoderApp: App {
    @NSApplicationDelegateAdaptor(DoomCoderAppDelegate.self) private var appDelegate
    @State private var sleepManager = SleepManager.shared
    @State private var updaterViewModel = CheckForUpdatesViewModel()
    @State private var tracking = AgentTrackingManager.shared

    init() {
        // Lightweight bindings only — heavy I/O moves to applicationDidFinishLaunching.
        AgentTrackingManager.shared.bind(sleepManager: SleepManager.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarWindowView(
                sleepManager: sleepManager,
                updaterViewModel: updaterViewModel,
                tracking: tracking
            )
        } label: {
            Image(systemName: sleepManager.isActive ? "bolt.fill" : "bolt.slash.fill")
                .symbolRenderingMode(.monochrome)
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView(sleepManager: sleepManager)
        }
        .windowResizability(.contentSize)

        Window("About Doom Coder", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("Configure Agents", id: "configureAgents") {
            ConfigureAgentsViewV2()
        }
        .windowResizability(.contentSize)

        Window("Track Agents", id: "trackAgents") {
            TrackAgentsView()
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - AppDelegate
final class DoomCoderAppDelegate: NSObject, NSApplicationDelegate {
    private var whatsNewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prepare support dirs + SQLite store on main (cheap).
        AgentSupportDir.ensure()
        EventStore.shared.open()

        // Start the socket listener.
        HookSocketListener.shared.start { env in
            Task { @MainActor in AgentTrackingManager.shared.ingest(env) }
        }

        // Path-heal any installed hooks off the main thread (JSON I/O).
        Task.detached(priority: .utility) {
            AgentInstallerV2.healAllPaths()
        }

        NotificationDispatcher.shared.requestPermission()

        // Check for v1.8.5 → v1.9.0 migration (UI-driven in Configure window).
        _ = MigrationManager.checkNeeded()

        if !UserDefaults.standard.bool(forKey: WhatsNewSheet.defaultsKey) {
            showWhatsNew()
        }
    }

    @MainActor
    func showWhatsNew() {
        let hosting = NSHostingController(rootView: WhatsNewSheet(onDismiss: { [weak self] in
            self?.whatsNewWindow?.close()
            self?.whatsNewWindow = nil
        }))
        // Empty sizingOptions disables ALL SwiftUI → window size coupling
        // (no preferredContentSize getter, no min/max extrema). This breaks
        // the infinite updateConstraints → sizeThatFits → setNeedsUpdate loop.
        hosting.sizingOptions = []
        let contentSize = NSSize(width: 520, height: 440)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.setContentSize(contentSize)
        window.title = "What's New in DoomCoder"
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        whatsNewWindow = window
    }
}


