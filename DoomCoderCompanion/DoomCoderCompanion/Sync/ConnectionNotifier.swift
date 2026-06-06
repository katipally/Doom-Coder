// ConnectionNotifier.swift — DoomCoder Companion
//
// v6: posts a local notification when a connection is established or torn
// down, so the user gets feedback on both devices (the user reported never
// getting a notification when a device connected). De-duplicated so the
// same event fired from two code paths within a short window only alerts once.

import Foundation
import UserNotifications

@MainActor
final class ConnectionNotifier {

    static let shared = ConnectionNotifier()
    private init() {}

    private var lastFired: [String: Date] = [:]
    private let dedupeWindow: TimeInterval = 5

    func notifyConnected(macName: String?) {
        let name = macName ?? "your Mac"
        post(key: "connected-\(name)", title: "Connected", body: "Connected to \(name)")
    }

    func notifyDisconnected(macName: String?) {
        let name = macName ?? "your Mac"
        post(key: "disconnected-\(name)", title: "Disconnected", body: "Disconnected from \(name)")
    }

    private func post(key: String, title: String, body: String) {
        if let last = lastFired[key], Date().timeIntervalSince(last) < dedupeWindow { return }
        lastFired[key] = Date()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "conn-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
