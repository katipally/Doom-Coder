// AppDelegate.swift — DoomCode Companion
// UIApplicationDelegate shim wired into CompanionApp via @UIApplicationDelegateAdaptor.
// Handles remote-notification registration, silent-push delivery, and
// foreground notification presentation policy.

import UIKit
import UserNotifications
import BackgroundTasks
import CloudKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Best-effort periodic background refresh so the companion picks up Mac
    /// changes even when no silent push is delivered (iOS throttles those). The
    /// system decides the cadence; this is opportunistic, not a fixed timer.
    static let refreshTaskId = "com.doomcoder.app.companion.refresh"

    /// Tokens for `NotificationCenter` observers registered in
    /// `application(_:didFinishLaunchingWithOptions:)`. Stored so they can be
    /// removed in `deinit`; previously the blocks captured `self` strongly
    /// and the tokens were never invalidated. The `AppDelegate` is process-
    /// scoped so a leak here never grows unbounded, but the pattern is
    /// fragile under refactor.
    private var observerTokens: [NSObjectProtocol] = []

    deinit {
        // `deinit` of a `@MainActor` class runs non-isolated. We must NOT
        // touch `observerTokens` directly from here (the compiler will
        // reject it for non-Sendable types). Instead, capture the tokens
        // into a local `nonisolated(unsafe)` constant: the array's
        // elements (`NSObjectProtocol`) are reference types whose
        // identity is stable for the process lifetime, so passing them
        // through a non-isolated boundary is safe.
        let tokens = Self.nonisolatedTokens
        Self.nonisolatedTokens.removeAll()
        if !tokens.isEmpty {
            DispatchQueue.main.async {
                for token in tokens {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }
    }

    /// Process-wide mirror of `observerTokens` reachable from non-isolated
    /// `deinit`. Synchronized with the main-actor property through the
    /// `@MainActor` of the enclosing class; only read from `deinit`,
    /// which is the only non-isolated call site.
    private static nonisolated(unsafe) var nonisolatedTokens: [NSObjectProtocol] = []

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
            // `BGTaskScheduler.register` calls the closure with whatever
            // concrete subclass of `BGTask` the system hands us. We only
            // ever submit `BGAppRefreshTaskRequest`s whose runtime class
            // is `BGAppRefreshTask`, so the cast is safe in practice —
            // but we use a conditional cast + early-return to keep Swift
            // 6 strict concurrency happy and to make the failure mode
            // visible in the field.
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated {
                (UIApplication.shared.delegate as? AppDelegate)?
                    .handleAppRefresh(refresh)
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
        let activeToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                try? await UNUserNotificationCenter.current().setBadgeCount(0)
            }
        }
        observerTokens.append(activeToken)
        Self.nonisolatedTokens.append(activeToken)

        // (Re)schedule background refresh whenever we leave the foreground.
        let bgToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
                Task { @MainActor in self?.scheduleAppRefresh() }
        }
        observerTokens.append(bgToken)
        Self.nonisolatedTokens.append(bgToken)
        scheduleAppRefresh()

        return true
    }

    // MARK: - Background refresh

    /// Submits the next opportunistic refresh request (no-op if one is queued).
    /// Audit 2026-06: this method is called from both
    /// `didEnterBackgroundNotification` and from `handleAppRefresh`'s
    /// completion. Multiple in-flight calls are safe because
    /// `BGTaskScheduler.submit` is documented to coalesce: if a request
    /// with the same identifier is already queued, the new submit is a
    /// no-op. We still guard the call with a `scheduled` flag so the
    /// "noisy" case (every backgrounding re-submits) doesn't spam the
    /// system log.
    private var isRefreshScheduled = false

    func scheduleAppRefresh() {
        if isRefreshScheduled { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        // Earliest, not exact — iOS coalesces on its own schedule.
        // Request 2 min; iOS typically enforces a ~15 min minimum, but shorter
        // requests give the system more flexibility to wake us when radio is on.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            isRefreshScheduled = true
        } catch {
            print("[AppDelegate] BGAppRefresh submit failed: \(error)")
        }
    }

    /// Runs a single fetch + presence publish within the system's time budget,
    /// always chaining the next request so the cadence keeps going.
    private func handleAppRefresh(_ task: BGAppRefreshTask) {
        // Reset the scheduled flag so a fresh scheduleAppRefresh can re-arm
        // the cadence after this refresh completes.
        isRefreshScheduled = false
        scheduleAppRefresh()
        let work = Task { @MainActor in
            await CompanionSyncEngine.shared.fetchChanges()
            guard !Task.isCancelled else { task.setTaskCompleted(success: false); return }
            await CompanionSyncEngine.shared.publishCompanionStatus()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        // Only cancel here; the work task owns calling setTaskCompleted so it is
        // never invoked twice or off the main actor.
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - CloudKit share acceptance (pairing via link)

    /// Invoked when the user opens a DoomCode iCloud share link (the Mac's
    /// "Copy Invite Link" / Share). The app has no scene manifest, so the share
    /// callback lands here on `UIApplicationDelegate` (which also fires on cold
    /// launch, avoiding the SwiftUI SceneDelegate caveat). The QR-scan path
    /// accepts programmatically instead (see `CompanionSyncEngine.acceptShare`).
    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task { @MainActor in
            let ok = await CompanionSyncEngine.shared.acceptShareMetadata(cloudKitShareMetadata)
            if ok { Haptics.success() }
        }
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
        let userInfo = response.notification.request.content.userInfo
        if let slug = Self.agentSlug(from: userInfo) {
            Task { @MainActor in AppRouter.shared.openAgent(slug: slug) }
        }
        completionHandler()
    }

    /// Extracts the agent raw value from a notification payload. Local
    /// notifications (shared-DB delivery) carry a direct `"agent"` key; legacy
    /// CloudKit query-subscription pushes nested it under `ck.qry.af.agent.value`.
    private nonisolated static func agentSlug(from userInfo: [AnyHashable: Any]) -> String? {
        if let direct = userInfo["agent"] as? String, !direct.isEmpty { return direct }
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
