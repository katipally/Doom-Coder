// AppRouter.swift — DoomCoder Companion
// Lightweight global navigation router so external entry points (deep links and
// notification taps) can drive the UI: select the Dashboard tab and push a
// specific agent's logs. Kept tiny and @MainActor — no business logic.

import SwiftUI
import DoomCoderCore

enum RootTab: Hashable {
    case prompts, notes, dashboard, settings
}

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    private init() {}

    var selectedTab: RootTab = .prompts
    /// Navigation path for the Dashboard tab's NavigationStack.
    var agentPath: [TrackedAgent] = []

    /// Text handed off from Notes' "Turn into a prompt". PromptsView consumes it
    /// on appear: it opens a fresh chat with this text pre-filled in the input
    /// (it does NOT auto-send — the user can edit first).
    var pendingPromptSeed: String?

    /// Switches to the Prompts tab and seeds the composer with `text`.
    func composePrompt(seededWith text: String) {
        pendingPromptSeed = text
        selectedTab = .prompts
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
