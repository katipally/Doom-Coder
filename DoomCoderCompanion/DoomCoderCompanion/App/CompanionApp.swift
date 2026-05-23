// CompanionApp.swift — DoomCoder Companion
// Entry point for the iOS companion app.
// Boots CompanionSyncEngine and gates main UI behind OnboardingView.

import SwiftUI
import DoomCoderCore

@main
struct CompanionApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Persisted via App Group so NSE can read it too.
    @State private var onboardingDone: Bool = {
        AppGroupCache.defaults.object(forKey: "onboarding.completedAt") != nil
    }()

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingDone {
                    RootTabView()
                } else {
                    OnboardingView(onComplete: {
                        AppGroupCache.defaults.set(Date(), forKey: "onboarding.completedAt")
                        onboardingDone = true
                    })
                }
            }
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
