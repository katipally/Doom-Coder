import Foundation
import UserNotifications

// Fires a macOS notification when a tracked AI app transitions working state:
//   - idle → working:  "[App] is working…"  (after app was idle for ≥ 3 polls ≈ 6s)
//   - working → idle:  "[App] finished"      (after working ≥ 15s and idle for ≥ 12s)
//
// One notification per agent per session (resets when app goes idle / not running).
// Uses the aggregated `isWorking` signal (child processes + FSEvents + network bytes).
@MainActor
final class NotificationManager {

    static let shared = NotificationManager()

    // Idle polls required before a "done" notification fires (2s poll → 6 × 2s = 12s).
    private let requiredIdleSamples = 6

    // Minimum working polls before a "done" notification is meaningful (8 × 2s = 16s).
    private let minWorkingPollsBeforeNotify = 8

    // Idle polls required before a "start" notification fires (3 × 2s = 6s idle → then starts).
    private let requiredIdleBeforeStart = 3

    private var idleSampleCounts:    [String: Int]  = [:]
    private var workingSampleCounts: [String: Int]  = [:]
    private var wasWorking:          [String: Bool] = [:]
    private var notifiedDone:        Set<String>    = []   // reset when working resumes
    private var notifiedStart:       Set<String>    = []   // reset when app goes idle
    private var isAuthorized = false
    private var setupCalled  = false

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
    func record(app: TrackedApp) {
        guard app.isRunning else {
            // App not running — reset all state
            idleSampleCounts[app.id]    = 0
            workingSampleCounts[app.id] = 0
            wasWorking[app.id]          = false
            notifiedDone.remove(app.id)
            notifiedStart.remove(app.id)
            return
        }

        let prevWorking = wasWorking[app.id] ?? false

        if app.isWorking {
            workingSampleCounts[app.id, default: 0] += 1
            let idleCount = idleSampleCounts[app.id] ?? 0
            idleSampleCounts[app.id] = 0
            notifiedDone.remove(app.id)  // ready to notify again next idle transition

            // idle → working: fire "started" notification if app was idle long enough
            if !prevWorking && !notifiedStart.contains(app.id) && idleCount >= requiredIdleBeforeStart {
                notifiedStart.insert(app.id)
                sendStartNotification(appName: app.displayName)
            }
        } else {
            let idleCount = (idleSampleCounts[app.id] ?? 0) + 1
            idleSampleCounts[app.id] = idleCount
            notifiedStart.remove(app.id)  // reset so next working session re-notifies

            let hadEnoughWorkTime = (workingSampleCounts[app.id] ?? 0) >= minWorkingPollsBeforeNotify

            // working → idle: fire "done" notification after sustained idle
            if prevWorking && hadEnoughWorkTime &&
               idleCount == requiredIdleSamples &&
               !notifiedDone.contains(app.id) {
                notifiedDone.insert(app.id)
                workingSampleCounts[app.id] = 0
                sendDoneNotification(appName: app.displayName)
            }
        }

        wasWorking[app.id] = app.isWorking
    }

    private func sendStartNotification(appName: String) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(appName) is working…"
        content.body  = "A task has started. Doom Coder will notify you when it finishes."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "doomcoder.start.\(appName).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func sendDoneNotification(appName: String) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(appName) finished"
        content.body  = "The task appears to be complete — your agent has gone idle."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "doomcoder.done.\(appName).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
