// CompanionApp.swift — DoomCoder Companion
// Entry point for the iOS companion app.
// Boots CompanionSyncEngine and launches RootTabView directly. The app is
// fully usable on first launch with no Mac / iCloud / notifications — required
// by App Store Guideline 4.2.3 (standalone functionality).

import SwiftUI
import DoomCoderCore

@main
struct CompanionApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .onOpenURL { url in
                    handleDeeplink(url)
                }
        }
    }

    /// Handles `doomcoder://agent/<slug>` URLs.
    /// Navigates to AgentLogsView for the specified agent.
    private func handleDeeplink(_ url: URL) {
        guard url.scheme?.lowercased() == "doomcoder",
              url.host?.lowercased() == "agent",
              let slug = url.pathComponents.dropFirst().first, !slug.isEmpty
        else { return }
        // TODO: Navigate to AgentLogsView for the agent with raw value = slug
        // For now, this is a placeholder — full navigation requires environment object routing
        print("[CompanionApp] Deeplink to agent: \(slug)")
    }
}
