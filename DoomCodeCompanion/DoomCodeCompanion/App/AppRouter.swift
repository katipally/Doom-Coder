// AppRouter.swift — Doom Coder Companion
// Lightweight global navigation router so external entry points (deep links and
// notification taps) can drive the UI: select the Dashboard tab and push a
// specific agent's logs. Kept tiny and @MainActor — no business logic.

import SwiftUI
import DoomCodeCore

enum RootTab: Hashable {
    case prompts, notes, dashboard, settings
}

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    private init() {}

    var selectedTab: RootTab = .dashboard
    /// Navigation path for the Dashboard tab's NavigationStack.
    var agentPath: [TrackedAgent] = []

    /// Text handed off from Notes' "Turn into a prompt". PromptsView consumes it
    /// on appear: it opens a fresh chat with this text pre-filled in the input
    /// (it does NOT auto-send — the user can edit first).
    var pendingPromptSeed: String?

    /// Set when the user has previously denied notification permission. The
    /// Dashboard reads this to show a non-blocking "Notifications are off"
    /// banner that deep-links to System Settings. Auto-cleared on return if
    /// the user re-enables notifications there.
    var showsNotificationDeniedHint: Bool = false

    /// Bumped to force RootTabView to re-present the welcome sheet.
    /// Audit 2026-06: previously the welcome sheet was a one-way
    /// switch (dismiss sets a UserDefaults flag, never shown again).
    /// The new entry in SettingsView increments this counter; the
    /// RootTabView observes it via `onChange` and re-presents.
    var welcomeRequestCount: Int = 0

    /// Switches to the Prompts tab and seeds the composer with `text`.
    func composePrompt(seededWith text: String) {
        pendingPromptSeed = text
        selectedTab = .prompts
    }

    /// Re-present the welcome sheet. Bumps `welcomeRequestCount` so
    /// `RootTabView` re-evaluates.
    func showWelcome() {
        welcomeRequestCount += 1
    }

    /// Selects the Dashboard tab and pushes the given agent's logs.
    func openAgent(_ agent: TrackedAgent) {
        selectedTab = .dashboard
        agentPath = [agent]
    }

    /// Resolves a `doomcoder://agent/<slug>` style slug (the agent raw value).
    func openAgent(slug: String) {
        guard let agent = TrackedAgent(rawValue: slug) else { return }
        openAgent(agent)
    }
}
