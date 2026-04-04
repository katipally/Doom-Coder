import Foundation
import UserNotifications

// Tracks per-app CPU idle samples and fires a macOS notification when a tracked
// AI tool appears to have finished its task (CPU < 2% for ~2 continuous minutes).
//
// NOTE: requestAuthorization() is NOT called from init() to avoid a startup crash
// on macOS Sequoia with ad-hoc signed apps. Call setup() after the app fully launches.
@MainActor
final class NotificationManager {

    static let shared = NotificationManager()

    // 12 samples × 10s polling interval ≈ 2 minutes of sustained idle CPU
    private let requiredIdleSamples = 12
    private let idleCPUThreshold: Double = 2.0

    private var idleSampleCounts: [String: Int] = [:]
    private var notifiedApps: Set<String> = []
    private var isAuthorized = false
    private var setupCalled = false

    private init() {}

    // Call once after the app has fully launched (not during init).
    // Uses the async throwing API to avoid completion-handler threading issues.
    func setup() {
        guard !setupCalled else { return }
        setupCalled = true
        Task {
            do {
                isAuthorized = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            } catch {
                // Notifications unavailable (e.g. unsigned app, sandboxing, etc.) — silently skip
                isAuthorized = false
            }
        }
    }

    // Called each polling cycle for every running tracked app.
    func record(app: TrackedApp) {
        guard app.isRunning, let cpu = app.cpuPercent else {
            idleSampleCounts[app.id] = 0
            notifiedApps.remove(app.id)
            return
        }

        if cpu < idleCPUThreshold {
            let count = (idleSampleCounts[app.id] ?? 0) + 1
            idleSampleCounts[app.id] = count
            if count == requiredIdleSamples && !notifiedApps.contains(app.id) {
                notifiedApps.insert(app.id)
                sendIdleNotification(appName: app.displayName)
            }
        } else {
            idleSampleCounts[app.id] = 0
            notifiedApps.remove(app.id)
        }
    }

    private func sendIdleNotification(appName: String) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "🤖 Task May Be Complete"
        content.body = "\(appName) has gone idle — your task may be complete."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "doomcoder.idle.\(appName).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
