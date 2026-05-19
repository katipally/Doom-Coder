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

        // Show the most recent What's New sheet (checked newest-first).
        if !UserDefaults.standard.bool(forKey: WhatsNewSheet230.defaultsKey) {
            Task { @MainActor in self.showWhatsNew230() }
        } else if !UserDefaults.standard.bool(forKey: WhatsNewSheet220.defaultsKey) {
            Task { @MainActor in self.showWhatsNew220() }
        } else if !UserDefaults.standard.bool(forKey: WhatsNewSheetV2.defaultsKey) {
            Task { @MainActor in self.showWhatsNewV2() }
        } else if !UserDefaults.standard.bool(forKey: WhatsNewSheet.defaultsKey) {
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
    func showWhatsNew230() {
        let hosting = NSHostingController(rootView: WhatsNewSheet230(onDismiss: { [weak self] in
            self?.whatsNewWindow?.close()
            self?.whatsNewWindow = nil
        }))
        hosting.sizingOptions = []
        let contentSize = NSSize(width: 520, height: 460)
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
        // Mark every older sheet as seen so users don't see them next launch.
        UserDefaults.standard.set(true, forKey: WhatsNewSheet220.defaultsKey)
        UserDefaults.standard.set(true, forKey: WhatsNewSheetV2.defaultsKey)
        UserDefaults.standard.set(true, forKey: WhatsNewSheet.defaultsKey)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        whatsNewWindow = window
    }

    @MainActor
    func showWhatsNew220() {
        let hosting = NSHostingController(rootView: WhatsNewSheet220(onDismiss: { [weak self] in
            self?.whatsNewWindow?.close()
            self?.whatsNewWindow = nil
        }))
        hosting.sizingOptions = []
        let contentSize = NSSize(width: 520, height: 420)
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
        // Mark older sheets as seen so users don't see them on the next launch.
        UserDefaults.standard.set(true, forKey: WhatsNewSheetV2.defaultsKey)
        UserDefaults.standard.set(true, forKey: WhatsNewSheet.defaultsKey)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        whatsNewWindow = window
    }

    @MainActor
    func showWhatsNewV2() {
        let hosting = NSHostingController(rootView: WhatsNewSheetV2(onDismiss: { [weak self] in
            self?.whatsNewWindow?.close()
            self?.whatsNewWindow = nil
        }))
        hosting.sizingOptions = []
        let contentSize = NSSize(width: 520, height: 460)
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
        // Also mark v1.9 as seen — users upgrading past v2 shouldn't see the
        // older sheet on their next launch after dismissing this one.
        UserDefaults.standard.set(true, forKey: WhatsNewSheet.defaultsKey)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        whatsNewWindow = window
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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        whatsNewWindow = window
    }
}


