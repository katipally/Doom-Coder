// CompanionApp.swift — DoomCoder Companion
// Entry point for the iOS companion app.
// Boots CompanionSyncEngine, registers the BGAppRefreshTask, and gates the
// main UI behind OnboardingView until setup is completed.

import SwiftUI
import BackgroundTasks
import DoomCoderCore

@main
struct CompanionApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Persisted via App Group so NSE can read it too.
    @State private var onboardingDone: Bool = {
        AppGroupCache.defaults.object(forKey: "onboarding.completedAt") != nil
    }()

    /// Session key extracted from a `doomcoder://session/<key>` deeplink.
    /// AgentsView observes this to push SessionDetailView automatically.
    @State private var deeplinkSessionKey: String? = nil

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingDone {
                    RootTabView(deeplinkSessionKey: $deeplinkSessionKey)
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

    /// Handles `doomcoder://session/<sessionKey>` URLs produced by tapping a
    /// Live Activity or Dynamic Island. The Xcode project must declare the
    /// `doomcoder` URL scheme in CFBundleURLTypes (Info.plist) for this to fire.
    private func handleDeeplink(_ url: URL) {
        guard url.scheme?.lowercased() == "doomcoder",
              url.host?.lowercased() == "session",
              let key = url.pathComponents.dropFirst().first, !key.isEmpty
        else { return }
        deeplinkSessionKey = key
    }
}
