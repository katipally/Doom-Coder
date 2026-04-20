import SwiftUI
import AppKit
import UserNotifications

@main
struct DoomCoderApp: App {
    @NSApplicationDelegateAdaptor(DoomCoderAppDelegate.self) private var appDelegate
    @State private var sleepManager = SleepManager.shared
    @State private var updaterViewModel = CheckForUpdatesViewModel.shared

    var body: some Scene {
        // No MenuBarExtra — replaced by NSStatusItem + NSPanel wired
        // by DoomCoderAppDelegate. We still register Window scenes so
        // openWindow(id:) keeps working for Configure / Settings / About.
        //
        // `.defaultLaunchBehavior(.suppressed)` prevents SwiftUI from
        // auto-instantiating + showing the first Window scene on launch
        // (LSUIElement apps otherwise get a stray Settings window).
        Window("Settings", id: "settings") {
            SettingsView(sleepManager: sleepManager)
                .background(WindowOpenerBridge())
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("About Doom Coder", id: "about") {
            AboutView()
                .background(WindowOpenerBridge())
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Configure Agents", id: "configureAgents") {
            ConfigureAgentsViewV2()
                .background(WindowOpenerBridge())
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

// MARK: - AppDelegate
final class DoomCoderAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var whatsNewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prepare support dirs + SQLite store on main (cheap).
        AgentSupportDir.ensure()
        PauseFlag.clearOnLaunch()
        EventStore.shared.open()

        // Re-apply curated notification defaults for users upgrading from
        // v4.0 (some of whom had legacy "notify every tool call" prefs).
        ChannelStore.migratePrefsIfNeeded()

        // Copy dc-hook to a stable path that survives Xcode rebuilds.
        AgentInstallerV2.ensureStableHelper()

        // Start the socket listener.
        HookSocketListener.shared.start { env in
            Task { @MainActor in AgentTrackingManager.shared.ingest(env) }
        }

        // Path-heal any installed hooks off the main thread (JSON I/O).
        Task.detached(priority: .utility) {
            AgentInstallerV2.healAllPaths()
        }

        // Set notification delegate BEFORE requesting permission so
        // foreground banners are enabled from the very first grant.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        NotificationDispatcher.shared.requestPermission()

        // Check for v1.8.5 → v1.9.0 migration (UI-driven in Configure window).
        _ = MigrationManager.checkNeeded()

        // Install the status bar item + wire the global hotkey.
        Task { @MainActor in
            // Belt-and-braces: even with .defaultLaunchBehavior(.suppressed),
            // older SDK paths or stale saved window state can briefly spawn
            // a Settings/About/Configure window at launch. Close any that
            // appear before the user ever sees them.
            let auxIDs: Set<String> = ["settings", "about", "configureAgents"]
            for win in NSApp.windows {
                if let id = win.identifier?.rawValue, auxIDs.contains(id) {
                    win.close()
                }
            }

            StatusItemController.shared.install()
            GlobalHotkey.shared.register {
                FloatingPanelController.shared.toggle()
            }

            // DoomCoder ON = Mac stays awake. If the master toggle was on at
            // last quit (or this is first launch), start sleep prevention now.
            // Mode and duration are just configuration — enabling is automatic.
            let masterOn = UserDefaults.standard.object(forKey: "doomcoder.masterEnabled") as? Bool ?? true
            if masterOn {
                SleepManager.shared.enable()
            }
        }

        if !UserDefaults.standard.bool(forKey: WhatsNewSheet.defaultsKey) {
            Task { @MainActor in self.showWhatsNew() }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notification banners even when DoomCoder is in the foreground.
    /// Menu-bar-only apps (LSUIElement) are always "foreground", so without
    /// this delegate method macOS silently drops every local notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Handle the user tapping a notification banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Bring the panel forward on tap.
        await MainActor.run {
            FloatingPanelController.shared.show()
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


