import AppKit
import SwiftUI

// NSStatusItem owner replacing MenuBarExtra.
// - Left click (or no modifier)  → toggle floating panel
// - Right click (or ctrl-click)   → show NSMenu with Open / About / Settings / Configure / Quit
// - Icon reflects sleep state (bolt.fill / bolt.slash.fill) and live agents count.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?

    private override init() {
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeft
        }

        refreshIcon()
        startObserving()
    }

    // MARK: - Observation of @Observable state

    /// Re-arming withObservationTracking loop. Each onChange call fires
    /// once per access-set, so we refresh the icon and re-arm.
    private func startObserving() {
        withObservationTracking {
            // Track every property of `SleepManager` that affects the
            // menu-bar icon so we re-render the moment any of them
            // changes. `withObservationTracking` re-arms itself in
            // `onChange`.
            _ = SleepManager.shared.isActive
            _ = SleepManager.shared.masterEnabled
            _ = SleepManager.shared.isSnoozed
            _ = AgentTrackingManager.shared.lastAnyHookAt
        } onChange: {
            Task { @MainActor [weak self] in
                self?.refreshIcon()
                self?.startObserving()
            }
        }
    }

    // MARK: - Icon

    func refreshIcon() {
        guard let button = statusItem?.button else { return }
        // Icon tracks the master toggle (DoomCode on/off), not the sleep
        // assertion. When master is OFF the app is fully idle — bolt.slash.
        // When master is on AND a snooze is active, swap to moon.zzz.fill so
        // the user can spot the override at a glance in the menu bar.
        let master = SleepManager.shared.masterEnabled
        let snoozed = SleepManager.shared.isSnoozed
        let name: String
        if !master { name = "bolt.slash.fill" }
        else if snoozed { name = "moon.zzz.fill" }
        else { name = "bolt.fill" }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Doom Code")
        img?.isTemplate = true
        button.image = img

        let liveCount = AgentTrackingManager.shared.hookFreshAgents.count
        button.title = liveCount > 0 ? " \(liveCount)" : ""
        // VoiceOver label: "Doom Code — 2 agents active" or "Doom Code — idle"
        let countLabel: String
        if snoozed {
            countLabel = "snoozed"
        } else if liveCount > 0 {
            countLabel = "\(liveCount) agent\(liveCount == 1 ? "" : "s") active"
        } else {
            countLabel = master ? "idle" : "suspended"
        }
        button.toolTip = "Doom Code — \(countLabel)"
        button.setAccessibilityLabel("Doom Code — \(countLabel)")
        // macOS 26 menu-bar pattern: dim the icon via contentTintColor
        // (not alphaValue, which would dim the badge title too).
        button.contentTintColor = master ? nil : .secondaryLabelColor
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            showContextMenu(from: sender)
        } else {
            FloatingPanelController.shared.toggle()
        }
    }

    private func showContextMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: "Open Doom Code", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let configure = NSMenuItem(title: "Configure Agents…", action: #selector(openConfigure), keyEquivalent: "")
        configure.target = self
        menu.addItem(configure)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: "About Doom Code", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit DoomCode", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Assign temporarily so performClick presents it; clear after
        // so future left-clicks still reach handleClick.
        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - Menu actions

    @objc private func openPanel() {
        FloatingPanelController.shared.recenter()
        FloatingPanelController.shared.show()
    }

    @objc private func openConfigure() {
        NSApp.activate()
        WindowOpener.open(.configureAgents)
    }

    @objc private func openSettings() {
        NSApp.activate()
        WindowOpener.openSettings()
    }

    @objc private func openAbout() {
        NSApp.activate()
        WindowOpener.open(.about)
    }

    @objc private func quit() {
        SleepManager.shared.prepareForTermination()
        NSApp.terminate(nil)
    }
}

// MARK: - WindowOpener

/// Minimal wrapper around the SwiftUI openWindow env value for code
/// paths that run outside of a View body (status item, panel). Posts a
/// notification that an invisible `WindowOpenerBridge` view observes.
@MainActor
enum WindowOpener {
    enum Target: String {
        case about
        case configureAgents
        case prompts
        case notes
        case whatsNew
    }

    static func open(_ target: Target) {
        NotificationCenter.default.post(name: .dcOpenWindow, object: target.rawValue)
    }

    /// Settings now lives inside the Configure window. Open Configure and focus
    /// the Settings tab — works whether or not the window is already open.
    static func openSettings() {
        // Set the router's tab first so the window can read it on
        // appear (or via onChange while it's already open), then open
        // the window. No more racy pendingTab static.
        AppRouter.shared.requestOpenSettings()
        open(.configureAgents)
    }

    /// Connections (companion devices) lives in the Configure window's
    /// Connections tab. Open Configure and focus that tab — works whether or
    /// not the window is already open. Mirrors `openSettings()`.
    static func openConnections() {
        AppRouter.shared.requestOpenConnections()
        open(.configureAgents)
    }
}

extension Notification.Name {
    static let dcOpenWindow = Notification.Name("com.doomcoder.openWindow")
    static let dcSelectConfigureTab = Notification.Name("com.doomcoder.selectConfigureTab")
}

/// Invisible SwiftUI view that listens for dcOpenWindow notifications
/// and invokes the SwiftUI openWindow env value (the only supported
/// way to open a Scene-registered Window in SwiftUI on macOS).
struct WindowOpenerBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .dcOpenWindow)) { note in
                guard let id = note.object as? String else { return }
                // Every target (settings / about / configureAgents / prompts /
                // notes) is now a real registered Window scene.
                openWindow(id: id)
            }
    }
}
