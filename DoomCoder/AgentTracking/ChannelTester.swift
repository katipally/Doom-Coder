import Foundation
@preconcurrency import UserNotifications
import OSLog

// Fires a real test notification to a single channel, bypassing dedupe logic.
enum ChannelTester {
    private static let logger = Logger(subsystem: "com.doomcoder", category: "channel-tester")

    /// Send a test notification on the given channel.
    @MainActor
    static func sendTest(channel: Channel, completion: @MainActor @Sendable @escaping (Bool, String) -> Void) {
        switch channel {
        case .macNotification:
            sendMacTest(completion: completion)
        case .iOSCompanion:
            sendiOSTest(completion: completion)
        }
    }

    enum Channel: String, CaseIterable, Identifiable {
        case macNotification = "macOS"
        case iOSCompanion = "iOS"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .macNotification: return "macOS Notification"
            case .iOSCompanion:    return "iOS Companion"
            }
        }

        var icon: String {
            switch self {
            case .macNotification: return "bell.badge.fill"
            case .iOSCompanion:    return "iphone.gen3.badge.play"
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
                    completion(false, "Notification permission not granted. Enable in System Settings → Notifications → DoomCoder.")
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "DoomCoder — Test"
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

    // MARK: - iOS Companion Test

    @MainActor
    private static func sendiOSTest(completion: @MainActor @Sendable @escaping (Bool, String) -> Void) {
        guard CloudKitSyncEngine.shared.isAvailable else {
            completion(false, "iCloud is not available — sign in to iCloud on this Mac to use the iOS companion.")
            return
        }
        Task { @MainActor in
            let ok = await NotificationDispatcher.shared.sendTest(channel: .iOS)
            completion(ok, ok ? "Sent to iOS companion via iCloud." : "Failed to enqueue iCloud push.")
        }
    }
}
