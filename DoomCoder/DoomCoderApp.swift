import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

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
        // WindowOpenerBridge re-routes any legacy `settings` open
        // request to Configure with the Settings tab pre-selected.

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

        // Start process monitor: NSWorkspace IDE notifications + CLI proc_listpids scan.
        _ = AgentProcessMonitor.shared

        // v3.1 one-shot: default-on launch-at-login. Companion users expect
        // remote control without first opening DoomCoder on the Mac. The
        // Configure pane's manual toggle continues to honor opt-out after
        // this — we only register if the migration flag has never run.
        let loginItemFlagKey = "migration.v3_1.loginItemRegistered"
        if UserDefaults.standard.bool(forKey: loginItemFlagKey) == false {
            if SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: loginItemFlagKey)
        }

        // Re-apply curated notification defaults for users upgrading from
        // v4.0 (some of whom had legacy "notify every tool call" prefs).
        ChannelStore.migratePrefsIfNeeded()
        // v2.x → v3.0: drop ntfy field, default-enable iOS companion channel.
        ChannelStore.migrateRemoveNtfyIfNeeded()

        // Start CloudKit sync engine (no-op until iCloud account confirms).
        CloudKitSyncEngine.shared.start()

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

        // Show the most recent What's New sheet on first launch after upgrade.
        if !UserDefaults.standard.bool(forKey: WhatsNewSheet300.defaultsKey) {
            Task { @MainActor in self.showWhatsNew300() }
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

    /// Silent push from CloudKit subscriptions.
    /// CKSyncEngine.fetchChanges() performs a delta fetch that delivers any
    /// new ControlCommand and Settings records, replacing the old separate
    /// drainPending() + fetchSettings() calls.
    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { @MainActor in
            await CloudKitSyncEngine.shared.fetchChanges()
            CloudKitSyncEngine.shared.publishMacStatus()
        }
    }

    /// Publish an "offline" MacStatus synchronously before the process exits
    /// so iOS sees the Mac go offline within seconds rather than waiting for
    /// the next 90 s heartbeat.
    func applicationWillTerminate(_ notification: Notification) {
        CloudKitSyncEngine.shared.persistEngineStateNow()
        CloudKitSyncEngine.shared.publishOfflineMacStatusSync()
    }

    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // CloudKit subscriptions don't require us to forward this token,
        // but registering enables push delivery. No-op body.
    }

    @MainActor
    func showWhatsNew300() {
        let hosting = NSHostingController(rootView: WhatsNewSheet300(onDismiss: { [weak self] in
            self?.whatsNewWindow?.close()
            self?.whatsNewWindow = nil
        }))
        // Empty sizingOptions disables ALL SwiftUI → window size coupling
        // (no preferredContentSize getter, no min/max extrema). This breaks
        // the infinite updateConstraints → sizeThatFits → setNeedsUpdate loop.
        hosting.sizingOptions = []
        let contentSize = NSSize(width: 520, height: 480)
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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        whatsNewWindow = window
    }
}


