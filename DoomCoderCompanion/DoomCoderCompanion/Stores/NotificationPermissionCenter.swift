// NotificationPermissionCenter.swift — DoomCoder Companion
// Single entry point for the iOS notification permission lifecycle.
//
// Two responsibilities:
//   1. Trigger the system permission prompt exactly once per install when the
//      status is `.notDetermined`. Called from the WelcomeView's "Get Started"
//      button (a user-initiated moment, which is the only time iOS will
//      reliably present the prompt per HIG).
//   2. Expose the current status so RootTabView can surface a non-blocking
//      "Notifications are off" banner on cold launch when status is `.denied`.
//
// We never re-prompt the iOS dialog after a denial — Apple disallows it. The
// user must go through System Settings, which our banner deep-links to.

import Foundation
import UserNotifications

@MainActor
enum NotificationPermissionCenter {

    /// Returns the current notification authorization status.
    static func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Triggers the iOS permission prompt exactly once per install when the
    /// status is `.notDetermined`. Safe to call from any user-initiated
    /// context. No-op when already determined.
    ///
    /// Returns the resulting status (post-prompt).
    @discardableResult
    static func requestIfNeeded() async -> UNAuthorizationStatus {
        let current = await currentStatus()
        guard current == .notDetermined else { return current }
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Permission prompts can fail on simulators with no notification
            // service configured, or when the user backgrounded the app during
            // the dialog. We swallow it — the next call will re-attempt.
        }
        return await currentStatus()
    }

    /// True when the user has previously denied notifications. Used to show
    /// the Dashboard banner on cold launch.
    static func isDenied() async -> Bool {
        await currentStatus() == .denied
    }
}
