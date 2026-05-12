import Foundation
@preconcurrency import UserNotifications
import CloudKit
import OSLog

// Diagnostic tests for the two notification channels: macOS local
// notifications and CloudKit round-trip (write → read → delete a
// DevicePresence record). Bypasses dedupe logic; safe to call from UI.
@MainActor
enum CloudKitDiagnostics {
    private static let logger = Logger(subsystem: "com.doomcoder", category: "diagnostics")

    enum Channel: String, CaseIterable, Identifiable {
        case macNotification = "macOS"
        case cloudKit = "iCloud"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .macNotification: return "macOS Notification"
            case .cloudKit:        return "iCloud / CloudKit"
            }
        }

        var icon: String {
            switch self {
            case .macNotification: return "bell.badge.fill"
            case .cloudKit:        return "icloud.fill"
            }
        }
    }

    static func sendTest(channel: Channel, completion: @MainActor @Sendable @escaping (Bool, String) -> Void) {
        switch channel {
        case .macNotification:
            sendMacTest(completion: completion)
        case .cloudKit:
            sendCloudKitTest(completion: completion)
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

            let request = UNNotificationRequest(
                identifier: "doomcoder-test-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
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

    // MARK: - CloudKit Round-Trip Test

    private static func sendCloudKitTest(completion: @MainActor @Sendable @escaping (Bool, String) -> Void) {
        Task { @MainActor in
            do {
                let container = CKContainer(identifier: "iCloud.com.doomcoder.app")
                let db = container.privateCloudDatabase

                let recordID = CKRecord.ID(recordName: "diagnostics-\(UUID().uuidString)")
                let record = CKRecord(recordType: "DevicePresence", recordID: recordID)
                record["deviceName"] = "DoomCoder Diagnostic" as CKRecordValue
                record["platform"] = "macOS" as CKRecordValue
                record["lastSeenAt"] = Date() as CKRecordValue

                _ = try await db.save(record)

                let fetched = try await db.record(for: recordID)
                guard fetched.recordType == "DevicePresence" else {
                    completion(false, "CloudKit: fetched record type mismatch")
                    return
                }

                try await db.deleteRecord(withID: recordID)
                completion(true, "CloudKit round-trip OK (write → read → delete)")
            } catch {
                logger.error("CloudKit diagnostic failed: \(error.localizedDescription, privacy: .public)")
                completion(false, "CloudKit error: \(error.localizedDescription)")
            }
        }
    }
}
