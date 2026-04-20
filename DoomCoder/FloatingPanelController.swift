import AppKit
import SwiftUI

// MARK: - KeyablePanel

// Borderless NSPanel that can become the key window so our inner SwiftUI
// content receives keyboard events (Escape, Tab, etc). `.nonactivatingPanel`
// on its own normally reports canBecomeKey = false.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - FloatingPanelController

// Raycast/Spotlight-style floating panel.
//
// - Dynamic size: SwiftUI reports intrinsic content size; we resize the panel.
// - Movable via background drag; we track user-moves vs programmatic resizes.
// - Entrance = alpha fade only (no layer anchorPoint tricks — those shift the
//   hosting view visually on re-open, clipping content).
// - Dismiss: Escape, click-outside (resignKey), global hotkey toggle.
@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    static let shared = FloatingPanelController()

    private var panel: KeyablePanel?
    private var hosting: NSHostingController<PanelRootView>?
    private var localKeyMonitor: Any?
    private var userMovedPanel = false
    private var isProgrammaticResize = false

    // Entrance counter bumped on every show — used as a SwiftUI `.id()` so the
    // inner tree re-mounts cleanly, re-triggering the appear animation.
    @Published private(set) var showToken: Int = 0

    private let defaultWidth: CGFloat = 480

    private(set) var isVisible: Bool = false

    private override init() { super.init() }

    // MARK: - Public

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let panel = ensurePanel()
        positionIfNeeded(panel)

        showToken &+= 1

        // Pure alpha entrance; SwiftUI scaleEffect on inner content handles
        // the spring entrance without touching AppKit layers.
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        isVisible = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        installLocalKeyMonitor()
    }

    func hide() {
        guard let panel, isVisible else { return }
        removeLocalKeyMonitor()
        isVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    /// Called by SwiftUI when the intrinsic content size changes.
    func resize(to contentSize: NSSize) {
        guard let panel else { return }
        let width = contentSize.width > 0 ? contentSize.width : defaultWidth
        let height = max(1, contentSize.height)

        var frame = panel.frame
        let dw = width - frame.size.width
        let dh = height - frame.size.height
        guard abs(dw) > 0.5 || abs(dh) > 0.5 else { return }

        frame.size = NSSize(width: width, height: height)
        // Keep top edge stable (grow/shrink downward from the top).
        frame.origin.y -= dh
        isProgrammaticResize = true

        // Animate the NSPanel frame in sync with the SwiftUI content
        // (accordion, row inserts, etc.). 0.28s ease-out roughly matches
        // DCAnim.accordion's effective spring settle time, so the window
        // grows smoothly instead of snapping.
        let oldSize = panel.frame.size
        let sizeDelta = max(abs(width - oldSize.width), abs(dh))
        let animate = sizeDelta > 1.5
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            } completionHandler: {
                Task { @MainActor [weak self] in
                    self?.isProgrammaticResize = false
                }
            }
        } else {
            panel.setFrame(frame, display: true, animate: false)
            isProgrammaticResize = false
        }
    }

    /// Recenter panel (invoked from right-click menu "Open DoomCoder").
    func recenter() {
        userMovedPanel = false
        if let panel { positionCentered(panel) }
    }

    // MARK: - Setup

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }

        let rootView = PanelRootView(
            sleepManager: SleepManager.shared,
            updaterViewModel: CheckForUpdatesViewModel.shared,
            tracking: AgentTrackingManager.shared,
            dismiss: { [weak self] in self?.hide() }
        )
        let hc = NSHostingController(rootView: rootView)
        hc.sizingOptions = [] // prevent sizeThatFits recursion
        self.hosting = hc

        let initialRect = NSRect(x: 0, y: 0, width: defaultWidth, height: 200)
        let panel = KeyablePanel(
            contentRect: initialRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hc
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        if let cv = panel.contentView {
            cv.wantsLayer = true
            cv.layer?.cornerRadius = 18
            cv.layer?.masksToBounds = true
            cv.layer?.backgroundColor = NSColor.clear.cgColor
        }

        self.panel = panel
        return panel
    }

    private func positionIfNeeded(_ panel: KeyablePanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        if !userMovedPanel || !visible.intersects(panel.frame) {
            positionCentered(panel)
        }
    }

    private func positionCentered(_ panel: KeyablePanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - visible.height * 0.22
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Key handling

    private func installLocalKeyMonitor() {
        removeLocalKeyMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                Task { @MainActor in self.hide() }
                return nil
            }
            return event
        }
    }

    private func removeLocalKeyMonitor() {
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            // Keep the panel visible while any DoomCoder auxiliary window
            // (Settings / About / Configure / Updates) is open, so the user
            // can bounce between surfaces without the panel disappearing.
            // Any OTHER app becoming active still dismisses the panel.
            let auxIDs: Set<String> = ["settings", "about", "configureAgents"]
            let hasAuxWindow = NSApp.windows.contains { w in
                guard w.isVisible else { return false }
                if let id = w.identifier?.rawValue, auxIDs.contains(id) { return true }
                // Sparkle "Check for Updates" dialog has no SwiftUI id;
                // match by class name / title for defence in depth.
                let title = w.title
                if title.contains("Update") || title.contains("DoomCoder") && w !== self.panel {
                    return true
                }
                return false
            }
            if hasAuxWindow { return }
            self.hide()
        }
    }

    func windowDidMove(_ notification: Notification) {
        if !isProgrammaticResize { userMovedPanel = true }
    }
}
