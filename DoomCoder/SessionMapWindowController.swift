import AppKit
import SwiftUI

// Singleton NSWindowController for the Session Map window.
// Created lazily on first open; closed/re-opened without recreating.

@MainActor
final class SessionMapWindowController: NSWindowController {
    static let shared = SessionMapWindowController()

    private init() {
        let rootView = SessionMapView()
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = []

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .unifiedTitleAndToolbar],
            backing: .buffered,
            defer: false
        )
        win.contentViewController = hosting
        win.title = "Session Map"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 700, height: 420)
        win.toolbarStyle = .unified
        win.setFrameAutosaveName("DoomCoderSessionMap")

        super.init(window: win)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        if let win = window, !win.isVisible {
            win.center()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
