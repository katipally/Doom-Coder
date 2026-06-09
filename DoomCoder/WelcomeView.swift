import SwiftUI
import AppKit

// MARK: - Welcome / first-launch onboarding
//
// Shown once, the first time a fresh install launches (gated by
// `OnboardingState`). Plain-language, three steps: how to open it, turn on
// notifications, and an optional Accessibility note. No marketing copy —
// just what the user needs to do to get going.
//
// Hosted by the `Window(id: "welcome")` scene in `DoomCoderApp.swift` and
// opened via `WindowOpener.open(.welcome)`.

struct WelcomeView: View {
    /// Closes the hosting window. Supplied by `WelcomeWindowController` so
    /// this works whether hosted in an NSWindow or a SwiftUI scene.
    var onDismiss: () -> Void = {}

    // Reflects the user's current (possibly rebound) shortcut so the copy
    // never lies. Defaults to ⌥ Space.
    private let shortcut = GlobalHotkey.shared.current.descriptionForUI

    @State private var notificationsGranted = false
    @State private var accessibilityTrusted = AccessibilityPermission.isTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            Divider()

            stepOpen
            stepNotifications
            stepAccessibility

            Divider()

            HStack {
                Text("Doom Coder lives in your menu bar — click the icon any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
        .onAppear {
            OnboardingState.markWelcomeSeen()
            NotificationDispatcher.shared.refreshPermissionStatus()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Doom Coder")
                .font(.title2.weight(.bold))
            Text("It keeps your Mac awake while your AI agents work, and pings your iPhone the second they need you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Steps

    private var stepOpen: some View {
        Step(number: "1", title: "Open it anytime") {
            HStack(spacing: 6) {
                Text("Press")
                Text(shortcut)
                    .font(.callout.weight(.semibold).monospaced())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                Text("to show or hide the window.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var stepNotifications: some View {
        Step(number: "2", title: "Turn on notifications") {
            VStack(alignment: .leading, spacing: 8) {
                Text("So you get pinged when an agent finishes or needs you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if notificationsGranted {
                    Label("Notifications are on.", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Button("Turn On Notifications") {
                        NotificationDispatcher.shared.requestPermission { granted in
                            notificationsGranted = granted
                            if !granted {
                                NotificationDispatcher.shared.openSystemSettings()
                            }
                        }
                    }
                }
            }
        }
    }

    private var stepAccessibility: some View {
        Step(number: "3", title: "Accessibility (optional)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("The \(shortcut) shortcut already works without it. Grant it later only if you rebind to a key that needs it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if accessibilityTrusted {
                    Label("Accessibility is granted.", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    // MARK: Actions

    private func finish() {
        OnboardingState.markWelcomeSeen()
        onDismiss()
    }
}

// MARK: - Step row

private struct Step<Content: View>: View {
    let number: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.callout.weight(.bold).monospacedDigit())
                .frame(width: 24, height: 24)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                content
            }
        }
    }
}

// MARK: - Onboarding state

/// First-launch gate. `welcomeSeen` is false only on a genuinely fresh
/// install; upgraders are detected by any previously-set "What's New" flag
/// and never see the welcome window.
@MainActor
enum OnboardingState {
    private static let welcomeKey = "doomcoder.onboarding.welcome.v1.seen"

    static var welcomeSeen: Bool {
        UserDefaults.standard.bool(forKey: welcomeKey)
    }

    static func markWelcomeSeen() {
        UserDefaults.standard.set(true, forKey: welcomeKey)
    }

    /// True if this looks like an existing user upgrading (any legacy
    /// What's New flag is set), so we should skip onboarding silently.
    static var looksLikeExistingUser: Bool {
        WhatsNewVersion.allCases.contains {
            UserDefaults.standard.bool(forKey: $0.defaultsKey)
        }
    }
}

// MARK: - Welcome window

/// Hosts `WelcomeView` in a standalone floating NSWindow. We don't use a
/// SwiftUI `Window` scene for this because the only way to open one at launch
/// is the `WindowOpenerBridge` notification, and that bridge lives inside the
/// floating panel's view tree — which isn't mounted until the panel is first
/// shown. A directly-owned NSWindow always opens, even on the very first run.
@MainActor
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = WelcomeView(onDismiss: { [weak self] in self?.close() })
        let hosting = NSHostingController(rootView: root)

        let win = NSWindow(contentViewController: hosting)
        win.title = "Welcome to Doom Coder"
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.center()

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
        window = nil
    }
}
