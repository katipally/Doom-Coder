import Foundation
import UserNotifications

// Tracks per-app CPU idle samples and fires a macOS notification when a tracked
// AI tool appears to have finished its task (CPU < 2% for ~2 continuous minutes).
@MainActor
final class NotificationManager {

    static let shared = NotificationManager()

    // 12 samples × 10s polling interval ≈ 2 minutes of sustained idle CPU
    private let requiredIdleSamples = 12
    private let idleCPUThreshold: Double = 2.0

    private var idleSampleCounts: [String: Int] = [:]  // app.id → consecutive idle samples
    private var notifiedApps: Set<String> = []          // suppress re-notification until active again

    private init() {
        requestAuthorization()
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Called each polling cycle for every running tracked app.
    func record(app: TrackedApp) {
        guard app.isRunning, let cpu = app.cpuPercent else {
            // App stopped running — reset tracking so next run triggers fresh detection
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
            // App became active again — reset so we notify again next time it idles
            idleSampleCounts[app.id] = 0
            notifiedApps.remove(app.id)
        }
    }

    private func sendIdleNotification(appName: String) {
        let content = UNMutableNotificationContent()
        content.title = "🤖 Task May Be Complete"
        content.body = "\(appName) has gone idle — your task may be complete."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "doomcoder.idle.\(appName).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
