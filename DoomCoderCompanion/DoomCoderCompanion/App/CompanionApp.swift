// CompanionApp.swift — Doom Coder Companion
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

    /// Handles `doomcoder://agent/<slug>` URLs by routing to the agent's logs.
    private func handleDeeplink(_ url: URL) {
        guard url.scheme?.lowercased() == "doomcoder",
              url.host?.lowercased() == "agent",
              let slug = url.pathComponents.dropFirst().first, !slug.isEmpty
        else { return }
        AppRouter.shared.openAgent(slug: slug)
    }
}
