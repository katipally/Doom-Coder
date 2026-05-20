// CompanionApp.swift — DoomCoder Companion
// Entry point for the iOS companion app.
// Boots CompanionSyncEngine, registers the BGAppRefreshTask, and gates the
// main UI behind OnboardingView until setup is completed.

import SwiftUI
import BackgroundTasks

@main
struct CompanionApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Persisted via App Group so NSE can read it too.
    @State private var onboardingDone: Bool = {
        AppGroupCache.defaults.object(forKey: "onboarding.completedAt") != nil
    }()

    var body: some Scene {
        WindowGroup {
            if onboardingDone {
                RootTabView()
            } else {
                OnboardingView(onComplete: {
                    AppGroupCache.defaults.set(Date(), forKey: "onboarding.completedAt")
                    onboardingDone = true
                })
            }
        }
    }
}
