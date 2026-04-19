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
        case .ntfy:
            sendNtfyTest(completion: completion)
        }
    }

    enum Channel: String, CaseIterable, Identifiable {
        case macNotification = "macOS"
        case ntfy = "ntfy"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .macNotification: return "macOS Notification"
            case .ntfy:            return "ntfy"
            }
        }

        var icon: String {
            switch self {
            case .macNotification: return "bell.badge.fill"
            case .ntfy:            return "paperplane.fill"
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

    // MARK: - ntfy Test

    private static func sendNtfyTest(completion: @MainActor @Sendable @escaping (Bool, String) -> Void) {
        let topic = NtfyTopic.getOrCreate()

        let server = NtfyTopic.server ?? "https://ntfy.sh"
        guard let url = URL(string: "\(server)/\(topic)") else {
            Task { @MainActor in
                completion(false, "Invalid ntfy URL.")
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("DoomCoder — Test", forHTTPHeaderField: "Title")
        request.setValue("high", forHTTPHeaderField: "Priority")
        request.setValue("white_check_mark", forHTTPHeaderField: "Tags")
        request.httpBody = "ntfy channel is working! You'll see agent alerts here.".data(using: .utf8)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { _, response, error in
            Task { @MainActor in
                if let error {
                    completion(false, "ntfy error: \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    completion(true, "ntfy test sent (topic: \(topic))")
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    completion(false, "ntfy returned HTTP \(code)")
                }
            }
        }.resume()
    }
}
