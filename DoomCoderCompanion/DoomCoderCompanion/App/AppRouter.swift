// AppRouter.swift — DoomCoder Companion
// Lightweight global navigation router so external entry points (deep links and
// notification taps) can drive the UI: select the Dashboard tab and push a
// specific agent's logs. Kept tiny and @MainActor — no business logic.

import SwiftUI
import DoomCoderCore

enum RootTab: Hashable {
    case tools, dashboard, settings
}

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    private init() {}

    var selectedTab: RootTab = .tools
    /// Navigation path for the Dashboard tab's NavigationStack.
    var agentPath: [TrackedAgent] = []

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
