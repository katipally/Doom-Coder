import SwiftUI
import AppKit
import UserNotifications

@main
struct DoomCoderApp: App {
    @NSApplicationDelegateAdaptor(DoomCoderAppDelegate.self) private var appDelegate

    var body: some Scene {
        // No MenuBarExtra — replaced by NSStatusItem + NSPanel wired
        // by DoomCoderAppDelegate. We still register Window scenes so
        // openWindow(id:) keeps working for Configure / About.
        //
        // Settings is no longer a standalone Window — it lives as the
        // 4th tab inside Configure (see ConfigureSettingsPane). The
        // floating panel's Settings button routes through
        // WindowOpener.openSettings() to Configure with Settings focused.
        //
        // All auxiliary windows are .floating + .auxiliary so they sit
        // above other apps (and full-screen apps), can join all Spaces,
        // and behave like the floating panel. macOS 26 native scene
        // modifier; replaces the legacy `FloatingWindowConfigurator`
        // NSViewRepresentable + per-window level = .floating dance.

        Window("About Doom Coder", id: "about") {
            AboutView()
                .background(WindowOpenerBridge())
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .windowLevel(.floating)

        Window("Configure Agents", id: "configureAgents") {
            ConfigureAgentsViewV2()
                .background(WindowOpenerBridge())
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .windowLevel(.floating)

        // Floating toolkit surfaces — each its own window (above all apps,
        // incl. full-screen), with a native traffic-light close button.
        // Default sizes are generous so the sidebar + editor (+ optional
        // inspector) never clip; min size tracks the actual content.
        Window("Prompts", id: "prompts") {
            NavigationStack { MacPromptsPane() }
                .frame(minWidth: 720, minHeight: 520)
                .background(WindowOpenerBridge())
                .background(FloatingWindowConfigurator(autosaveName: "doomcoder.window.prompts"))
        }
        .defaultSize(width: 1080, height: 700)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .windowLevel(.floating)

        Window("Notes", id: "notes") {
            NavigationStack { MacNotesPane() }
                .frame(minWidth: 700, minHeight: 480)
                .background(WindowOpenerBridge())
                .background(FloatingWindowConfigurator(autosaveName: "doomcoder.window.notes"))
        }
        .defaultSize(width: 1000, height: 660)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .windowLevel(.floating)

        // What's New — single SwiftUI scene; replaces the four legacy
        // showWhatsNew* methods. `WhatsNewHost` picks the highest-version
        // unseen sheet and advances to the next on dismiss.
        Window("What's New", id: "whatsNew") {
            WhatsNewHost()
                .background(WindowOpenerBridge())
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .windowLevel(.floating)
    }
}

// MARK: - AppDelegate
final class DoomCoderAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prepare support dirs + SQLite store on main (cheap).
        AgentSupportDir.ensure()
        PauseFlag.clearOnLaunch()
        EventStore.shared.open()

        // Start process monitor: NSWorkspace IDE notifications + CLI proc_listpids scan.
        _ = AgentProcessMonitor.shared

        // Re-apply curated notification defaults for users upgrading from
        // v4.0 (some of whom had legacy "notify every tool call" prefs).
        AgentNotificationStore.migrateIfNeeded()

        // Drop legacy per-agent channel overrides — channels are now a single
        // global mac + iPhone setting that applies to every agent.
        ChannelStore.migrateClearPerAgentOverridesIfNeeded()

        // Start the iCloud push pipeline (writes NotificationLog / MacStatus
        // / AgentConfig / AgentIcon CKRecords that the iOS companion app
        // subscribes to). Safe to call before iCloud account is ready —
        // the pusher waits for accountStatus internally.
        CloudKitPusher.shared.start()
        CloudKitPusherLifecycle.shared.start()

        // Copy dc-hook to a stable path that survives Xcode rebuilds.
        AgentInstallerV2.ensureStableHelper()

        // Start the socket listener.
        HookSocketListener.shared.start { env in
            Task { @MainActor in AgentTrackingManager.shared.ingest(env) }
        }

        // Path-heal any installed hooks off the main thread (JSON I/O).
        Task.detached(priority: .utility) {
            // Silent v2 → v3 migration: per-folder Copilot CLI installs →
            // global ~/.copilot/hooks/doomcoder.json. Idempotent, gated by
            // its own UserDefault flag.
            MigrationManager.migrateV2toV3()
            AgentInstallerV2.healAllPaths()
        }

        // Download agent icons from lobehub CDN in the background.
        // No-op if already cached; silent fallback on network failure.
        IconDownloader.prefetch()

        // Set notification delegate BEFORE requesting permission so
        // foreground banners are enabled from the very first grant.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        NotificationDispatcher.shared.requestPermission()

        // Register for remote notifications so CloudKit zone pushes trigger
        // an immediate fetchNow() instead of waiting for the 5s safety-net poll.
        // Requires aps-environment entitlement. No-op if already registered.
        NSApplication.shared.registerForRemoteNotifications()

        // Check for v1.8.5 → v1.9.0 migration (UI-driven in Configure window).
        _ = MigrationManager.checkNeeded()

        // Install the status bar item + wire the global hotkey.
        Task { @MainActor in
            // Belt-and-braces: even with .defaultLaunchBehavior(.suppressed),
            // older SDK paths or stale saved window state can briefly spawn
            // a Settings/About/Configure window at launch. Close any that
            // appear before the user ever sees them.
            let auxIDs: Set<String> = ["about", "configureAgents", "prompts", "notes"]
            for win in NSApp.windows {
                if let id = win.identifier?.rawValue, auxIDs.contains(id) {
                    win.close()
                }
            }

            StatusItemController.shared.install()
            GlobalHotkey.shared.register {
                FloatingPanelController.shared.toggle()
            }

            // Keep-awake intent (Off/On/Auto) is persisted and re-applied by
            // SleepManager.init, including the pre-2.5 migration. No need to
            // force-enable here — doing so would override a saved Auto/Off.
            _ = SleepManager.shared
        }

        // Show the highest-version unseen What's New sheet (if any).
        // `WhatsNewHost` picks the right one and advances on dismiss.
        // The Window scene is `.defaultLaunchBehavior(.suppressed)` so it
        // never auto-opens — we open it explicitly here.
        if WhatsNewVersion.highestUnseen() != nil {
            Task { @MainActor in
                WindowOpener.open(.whatsNew)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notification banners even when Doom Coder is in the foreground.
    /// Menu-bar-only apps (LSUIElement) are always "foreground", so without
    /// this delegate method macOS silently drops every local notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Remote CloudKit pushes (an iPhone ControlCommand arriving via the
        // high-priority `mac-controlcmd-query-v2` subscription) carry an alert
        // ONLY to earn apns-priority 10 (instant) delivery — they must NEVER show
        // a banner on the Mac. Suppress the display and kick an immediate fetch so
        // the command applies in ~1s. Local notifications (agent events, the
        // connectivity "check" ring) are not push-triggered, so they display
        // normally.
        if notification.request.trigger is UNPushNotificationTrigger {
            await MainActor.run { CloudKitPusher.shared.fetchNow() }
            return []
        }
        return [.banner, .sound, .list]
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

    // MARK: - Remote Notifications (APNs / CloudKit silent push)

    /// Called when Mac successfully registers with APNs.
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[Doom Coder] APNs device token registered (\(String(hex.prefix(8)))…)")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[Doom Coder] APNs registration failed: \(error.localizedDescription)")
    }

    /// CloudKit sends a silent content-available push when zone changes land.
    /// Trigger an immediate fetch so iOS commands apply in <3s instead of up to 15s.
    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { @MainActor in
            CloudKitPusher.shared.fetchNow()
        }
    }

}


