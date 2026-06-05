// AppDelegate.swift — DoomCoder Companion
// UIApplicationDelegate shim wired into CompanionApp via @UIApplicationDelegateAdaptor.
// Handles remote-notification registration, silent-push delivery, and
// foreground notification presentation policy.

import UIKit
import UserNotifications
import BackgroundTasks

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Best-effort periodic background refresh so the companion picks up Mac
    /// changes even when no silent push is delivered (iOS throttles those). The
    /// system decides the cadence; this is opportunistic, not a fixed timer.
    static let refreshTaskId = "com.doomcoder.app.companion.refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // One-shot v3 cleanup of legacy App Group keys / files.
        AppGroupCache.runV3MigrationOnce()
        AppGroupCache.enforceSchemaVersion()

        // Register the background-refresh handler before launch completes. Run
        // it on the main queue so we can hop onto the main actor safely (BGTask
        // is not Sendable, so it must not cross actor/thread boundaries).
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskId, using: .main
        ) { task in
            MainActor.assumeIsolated {
                (UIApplication.shared.delegate as? AppDelegate)?
                    .handleAppRefresh(task as! BGAppRefreshTask)
            }
        }

        // Sync engine start
        Task { @MainActor in
            CompanionSyncEngine.shared.start()
        }

        // Download agent icons into App Group so the NSE can attach them to banners.
        AgentIconFetcher.prefetchIfNeeded()

        application.registerForRemoteNotifications()

        // Clear the badge when the user comes back so it stays accurate.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                try? await UNUserNotificationCenter.current().setBadgeCount(0)
            }
        }

        // (Re)schedule background refresh whenever we leave the foreground.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in self.scheduleAppRefresh() }
        }
        scheduleAppRefresh()

        return true
    }

    // MARK: - Background refresh

    /// Submits the next opportunistic refresh request (no-op if one is queued).
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        // Earliest, not exact — iOS coalesces on its own schedule.
        // Request 2 min; iOS typically enforces a ~15 min minimum, but shorter
        // requests give the system more flexibility to wake us when radio is on.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[AppDelegate] BGAppRefresh submit failed: \(error)")
        }
    }

    /// Runs a single fetch within the system's time budget, always chaining
    /// the next request so the cadence keeps going.
    private func handleAppRefresh(_ task: BGAppRefreshTask) {
        scheduleAppRefresh()
        let work = Task { @MainActor in
            await CompanionSyncEngine.shared.fetchChanges()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        // Only cancel here; the work task owns calling setTaskCompleted so it is
        // never invoked twice or off the main actor.
        task.expirationHandler = { work.cancel() }
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
    /// v5.1: also refreshes the DiscoverableMac list when the
    /// push came from the public-DB CKQuerySubscription. The
    /// push payload is the same shape regardless of which
    /// subscription fired, so we always refresh both. CKQuery
    /// operations are cheap when the change-set is small.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            await CompanionSyncEngine.shared.handleRemoteNotification()
            await DiscoverableMacSubscription.shared.refresh()
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
        let userInfo = response.notification.request.content.userInfo
        if let slug = Self.agentSlug(from: userInfo) {
            Task { @MainActor in AppRouter.shared.openAgent(slug: slug) }
        }
        completionHandler()
    }

    /// Extracts the agent raw value from a CloudKit query-subscription payload:
    /// `userInfo["ck"]["qry"]["af"]["agent"]["value"]`.
    private nonisolated static func agentSlug(from userInfo: [AnyHashable: Any]) -> String? {
        guard
            let ck  = userInfo["ck"]  as? [String: Any],
            let qry = ck["qry"]       as? [String: Any],
            let af  = qry["af"]       as? [String: Any],
            let fld = af["agent"]     as? [String: Any],
            let val = fld["value"]    as? String
        else { return nil }
        return val
    }
}
