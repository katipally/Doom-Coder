import Foundation
@preconcurrency import UserNotifications
import OSLog
import DoomCodeCore

// Fires a real test notification to a single channel, bypassing dedupe logic.
enum ChannelTester {
    private static let logger = Logger(subsystem: "com.doomcoder", category: "channel-tester")

    /// Send a test notification on the given channel.
    @MainActor
    static func sendTest(channel: Channel, completion: @MainActor @Sendable @escaping (Bool, String) -> Void) {
        switch channel {
        case .macNotification:
            sendMacTest(completion: completion)
        case .cloudKit:
            sendCloudKitTest(completion: completion)
        }
    }

    enum Channel: String, CaseIterable, Identifiable {
        case macNotification = "macOS"
        case cloudKit = "iPhone / iPad"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .macNotification: return "macOS Notification"
            case .cloudKit:        return "iPhone / iPad (iCloud)"
            }
        }

        var icon: String {
            switch self {
            case .macNotification: return "bell.badge.fill"
            case .cloudKit:        return "iphone.gen3"
            }
        }
    }

    // MARK: - macOS Local Notification Test

    private static func sendMacTest(completion: @MainActor @Sendable @escaping (Bool, String) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                Task { @MainActor in
                    completion(false, "Permission error: \(error.localizedDescription)")
                }
                return
            }
            guard granted else {
                Task { @MainActor in
                    completion(false, "Notification permission not granted. Enable in System Settings → Notifications → DoomCode.")
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Doom Coder — Test"
            content.body = "✅ macOS notifications are working! You'll see agent alerts like this."
            content.sound = .default
            content.categoryIdentifier = "DOOMCODER_TEST"

            let request = UNNotificationRequest(identifier: "doomcoder-test-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
            center.add(request) { error in
                Task { @MainActor in
                    if let error {
                        completion(false, "Failed to deliver: \(error.localizedDescription)")
                    } else {
                        completion(true, "Test notification sent successfully!")
                    }
                }
            }
        }
    }

    // MARK: - CloudKit (iPhone / iPad) Test

    @MainActor
    private static func sendCloudKitTest(completion: @MainActor @Sendable @escaping (Bool, String) -> Void) {
        let pusher = CloudKitPusher.shared
        guard pusher.isReady else {
            completion(false, "iCloud sync isn't ready yet. Make sure you're signed in to iCloud and the Doom Coder iPhone app is installed.")
            return
        }
        let rec = NotificationLogRecord(
            sessionKey: "test",
            macId: pusher.macId,
            macName: pusher.macName,
            agent: "doomcoder",
            phase: "test",
            rawEvent: "test",
            title: "Doom Coder — Test",
            body: "✅ iPhone push channel is working! You'll see agent alerts on your iOS device.",
            channel: "iOS",
            success: true,
            ts: Date()
        )
        pusher.publishNotificationLog(rec)
        completion(true, "Test push queued — check your iPhone in a few seconds.")
    }
}
