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

        // Watch masterEnabled toggle (stored in UserDefaults) so the menu-bar
        // icon swaps between bolt.fill / bolt.slash immediately.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc private func userDefaultsChanged() {
        Task { @MainActor [weak self] in self?.refreshIcon() }
    }

    // MARK: - Observation of @Observable state

    /// Re-arming withObservationTracking loop. Each onChange call fires
    /// once per access-set, so we refresh the icon and re-arm.
    private func startObserving() {
        withObservationTracking {
            _ = SleepManager.shared.isActive
            _ = AgentTrackingManager.shared.liveSessions.count
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
        // Icon tracks the master toggle (DoomCoder on/off), not the sleep
        // assertion. When master is OFF the app is fully idle — bolt.slash.
        let master = UserDefaults.standard.object(forKey: "doomcoder.masterEnabled") as? Bool ?? true
        let name = master ? "bolt.fill" : "bolt.slash.fill"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "DoomCoder")
        img?.isTemplate = true
        button.image = img

        let liveCount = AgentTrackingManager.shared.liveSessions.count
        button.title = liveCount > 0 ? " \(liveCount)" : ""
        // Gently dim the icon when master is off so it's distinguishable at a glance.
        button.alphaValue = master ? 1.0 : 0.55
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

        let open = NSMenuItem(title: "Open DoomCoder", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let configure = NSMenuItem(title: "Configure Agents…", action: #selector(openConfigure), keyEquivalent: "")
        configure.target = self
        menu.addItem(configure)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: "About DoomCoder", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit DoomCoder", action: #selector(quit), keyEquivalent: "q")
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
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.open(.configureAgents)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.open(.settings)
    }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.open(.about)
    }

    @objc private func quit() {
        SleepManager.shared.disable()
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
        case settings
        case about
        case configureAgents
    }

    static func open(_ target: Target) {
        NotificationCenter.default.post(name: .dcOpenWindow, object: target.rawValue)
    }
}

extension Notification.Name {
    static let dcOpenWindow = Notification.Name("com.doomcoder.openWindow")
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
                openWindow(id: id)
            }
    }
}
