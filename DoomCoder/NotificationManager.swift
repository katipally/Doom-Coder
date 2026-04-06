import Foundation
import UserNotifications

// Fires a macOS notification when a tracked AI app transitions from "working" to "idle",
// indicating that a long-running task may have completed.
//
// Uses the aggregated `isWorking` signal (child processes + FSEvents + network bytes),
// which is more accurate and faster-responding than CPU sampling alone.
//
// Debounce rules:
//   - App must have been working for at least 15 seconds before a "done" notification fires.
//   - Once a notification fires for an app, won't fire again until the app starts working again.
@MainActor
final class NotificationManager {

    static let shared = NotificationManager()

    // Number of consecutive "idle" polls before firing notification.
    // Called from the 2s network timer → 6 polls × 2s ≈ 12s of sustained idle.
    private let requiredIdleSamples = 6

    // Minimum working duration (in polls) before we consider a "done" notification meaningful.
    // 8 polls × 2s ≈ 16s minimum working session.
    private let minWorkingPollsBeforeNotify = 8

    private var idleSampleCounts: [String: Int] = [:]
    private var workingSampleCounts: [String: Int] = [:]
    private var wasWorking: [String: Bool] = [:]
    private var notifiedApps: Set<String> = []
    private var isAuthorized = false
    private var setupCalled = false

    private init() {}

    // Call once after the app has fully launched (not during init).
    func setup() {
        guard !setupCalled else { return }
        setupCalled = true
        Task {
            do {
                isAuthorized = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            } catch {
                isAuthorized = false
            }
        }
    }

    // Called each poll cycle for every running tracked app.
    // Uses the aggregated isWorking signal to track working → idle transitions.
    func record(app: TrackedApp) {
        guard app.isRunning else {
            idleSampleCounts[app.id] = 0
            workingSampleCounts[app.id] = 0
            wasWorking[app.id] = false
            notifiedApps.remove(app.id)
            return
        }

        if app.isWorking {
            // Accumulate working time; reset idle counter and "notified" flag
            workingSampleCounts[app.id, default: 0] += 1
            idleSampleCounts[app.id] = 0
            notifiedApps.remove(app.id)
        } else {
            // App is idle — increment idle counter
            let idleCount = (idleSampleCounts[app.id] ?? 0) + 1
            idleSampleCounts[app.id] = idleCount

            let prevWorking = wasWorking[app.id] ?? false
            let hadEnoughWorkTime = (workingSampleCounts[app.id] ?? 0) >= minWorkingPollsBeforeNotify

            // Fire when: was working → now idle for requiredIdleSamples, AND worked long enough
            if prevWorking && hadEnoughWorkTime &&
               idleCount == requiredIdleSamples &&
               !notifiedApps.contains(app.id) {
                notifiedApps.insert(app.id)
                workingSampleCounts[app.id] = 0
                sendIdleNotification(appName: app.displayName)
            }
        }

        wasWorking[app.id] = app.isWorking
    }

    private func sendIdleNotification(appName: String) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Task Complete"
        content.body = "\(appName) has gone idle — your task may be done."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "doomcoder.idle.\(appName).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
