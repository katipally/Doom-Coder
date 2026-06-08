import SwiftUI
import AppKit
import Observation
import DoomCoderCore

// MARK: - AppRouter
//
// Centralized navigation router for the macOS app. Replaces the racy
// `ConfigureAgentsViewV2.pendingTab` static + `dcSelectConfigureTab`
// notification pattern with a single observable that the Configure window
// binds to directly. StatusItemController and FloatingPanelController
// call into this router to open windows; the window reads `selectedTab`
// on appear, so the race where opening Settings before the window exists
// drops the tab selection is gone.
//
// SwiftUI's `openWindow` env value still owns *window lifecycle* (open
// vs. close). The router only owns *which tab the window shows when it
// opens*.

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    /// Which tab the Configure window is currently showing. The Configure
    /// window binds to this via `@State private var router = AppRouter.shared`.
    var configureTab: ConfigTab = .agents

    /// Which agent the Configure window's Agents section has selected.
    var selectedAgent: TrackedAgent = .claude

    /// Bumped to request the Settings tab to be selected. Combined with
    /// `configureTab = .settings`, the Configure window reads both on
    /// appear and the Settings tab is shown. Belt-and-braces against the
    /// window-not-yet-created race.
    var openSettingsRequestCount: Int = 0

    enum ConfigTab: Hashable, CaseIterable, Identifiable {
        case agents, channels, activity, settings
        var id: Self { self }
        var displayName: String {
            switch self {
            case .agents:   "Agents"
            case .channels: "Connections"
            case .activity: "Activity"
            case .settings: "Settings"
            }
        }
    }

    init() {}

    /// Programmatically selects the Settings tab. The caller is then
    /// responsible for ensuring the Configure window is open.
    func requestOpenSettings() {
        configureTab = .settings
        openSettingsRequestCount &+= 1
    }

    /// Programmatically selects the Connections tab. The caller is then
    /// responsible for ensuring the Configure window is open. The window reads
    /// `configureTab` on appear and via onChange, so setting it is sufficient
    /// whether or not the window is already open.
    func requestOpenConnections() {
        configureTab = .channels
    }
}
