// AppDelegate.swift — DoomCoder Companion
// UIApplicationDelegate shim wired into CompanionApp via @UIApplicationDelegateAdaptor.
// Handles remote-notification registration, silent-push delivery, and
// foreground notification presentation policy.

import UIKit
import UserNotifications
import BackgroundTasks

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Request notification permission every launch. iOS only prompts
        // the user once; subsequent calls are no-ops if already granted.
        Task {
            try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }

        // Start sync engine and register BGTask on the main actor.
        Task { @MainActor in
            CompanionSyncEngine.shared.start()
            BackgroundRefresh.register()
            BackgroundRefresh.schedule()
        }

        // Download agent icons into App Group so the NSE can attach them to banners.
        AgentIconFetcher.prefetchIfNeeded()

        application.registerForRemoteNotifications()
        return true
    }

    // MARK: - Remote notifications

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // CloudKit manages its own subscription tokens; nothing extra needed here.
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[AppDelegate] Failed to register for remote notifications: \(error)")
    }

    /// Called for silent pushes (CloudKit subscription pings).
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            await CompanionSyncEngine.shared.handleRemoteNotification()
            completionHandler(.newData)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banner + sound + badge when a notification arrives while the app is foregrounded.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
