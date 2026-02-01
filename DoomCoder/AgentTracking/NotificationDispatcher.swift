import Foundation
import UserNotifications
import AppKit
import OSLog

// Fan-out for DoomCoder agent notifications. Honors the TrackingStore
// per-agent opt-out and the global ChannelStore (macOS local + ntfy).
// Minimal content only — no prompt text, no file paths over ntfy. 5-second
// dedupe window per (session, event).
@MainActor
final class NotificationDispatcher {
    static let shared = NotificationDispatcher()

    private let logger = Logger(subsystem: "com.doomcoder", category: "notify")
    private var lastDispatchAt: [String: Date] = [:]
    private let dedupeWindow: TimeInterval = 5

    // Cached permission status. Updated by `refreshPermissionStatus()` on
    // launch, on channel-toggle, and when the app becomes active.
    private(set) var permissionStatus: UNAuthorizationStatus = .notDetermined

    private init() {}

    // MARK: - Permission

    /// Asks macOS for notification permission. If the user has previously
    /// denied, this returns the cached .denied status without prompting
    /// again — callers should surface a "Open System Settings" link in that
    /// case. Safe to call repeatedly.
    func requestPermission(_ completion: (@MainActor (Bool) -> Void)? = nil) {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            self.permissionStatus = settings.authorizationStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                completion?(true)
            case .denied:
                completion?(false)
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                self.refreshPermissionStatus()
                completion?(granted)
            @unknown default:
                completion?(false)
            }
        }
    }

    /// Reads the current system-level status without prompting. Call on
    /// launch and whenever the app returns to foreground.
    func refreshPermissionStatus() {
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self.permissionStatus = settings.authorizationStatus
        }
    }

    /// Opens System Settings → Notifications → DoomCoder. Used when status
    /// is `.denied` and the user wants to re-enable.
    func openSystemSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.katipally.DoomCoder"
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Public dispatch

    struct Event: Sendable {
        let sessionKey: String
        let agent: TrackedAgent
        let event: String       // raw event name from the hook
    }

    func dispatch(_ ev: Event) {
        // Honor per-agent Tracking toggle (user opted this agent out).
        guard TrackingStore.isEnabled(ev.agent) else { return }

        let key = "\(ev.sessionKey)::\(ev.event)"
        if let last = lastDispatchAt[key], Date().timeIntervalSince(last) < dedupeWindow {
            return
        }
        lastDispatchAt[key] = Date()

        let title = titleFor(ev)
        let body = bodyFor(ev)
        let channels = ChannelStore.effectiveChannels(for: ev.agent)
        let ts = Date().timeIntervalSince1970

        if channels.macNotification {
            postLocal(title: title, body: body)
            EventStore.shared.insertNotification(
                sessionKey: ev.sessionKey, agent: ev.agent.rawValue, event: ev.event,
                title: title, body: body, channel: "macOS", success: true, ts: ts
            )
        }
        if channels.ntfy {
            postNtfy(title: title, body: body)
            EventStore.shared.insertNotification(
                sessionKey: ev.sessionKey, agent: ev.agent.rawValue, event: ev.event,
                title: title, body: body, channel: "ntfy", success: true, ts: ts
            )
        }
    }

    /// Sends a test notification on the chosen channel. Returns true if the
    /// request was successfully submitted (not a delivery guarantee).
    @discardableResult
    func sendTest(channel: TestChannel) async -> Bool {
        switch channel {
        case .macOS:
            let ok = await withCheckedContinuation { cont in
                requestPermission { granted in cont.resume(returning: granted) }
            }
            guard ok else { return false }
            postLocal(title: "DoomCoder", body: "macOS notifications are working ✨")
            return true
        case .ntfy:
            postNtfy(title: "DoomCoder", body: "ntfy channel is working ✨")
            return true
        }
    }

    enum TestChannel { case macOS, ntfy }

    // MARK: - Copy

    private func titleFor(_ ev: Event) -> String {
        let e = ev.event.lowercased()
        if e.contains("error") || e.contains("failure") { return "DoomCoder · failed" }
        if e.contains("sessionend") || e.contains("stop") || e == "taskcompleted" { return "DoomCoder · done" }
        if e.contains("permission") || e.contains("notification") || e.contains("elicitation") || e.contains("afteragentresponse") {
            return "DoomCoder · needs you"
        }
        if e.contains("sessionstart") { return "DoomCoder · started" }
        return "DoomCoder"
    }

    private func bodyFor(_ ev: Event) -> String {
        "\(ev.agent.displayName) — \(ev.event)"
    }

    // MARK: - macOS local

    private func postLocal(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { [weak self] err in
            if let err { self?.logger.error("local notify failed: \(err.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: - ntfy

    private func postNtfy(title: String, body: String) {
        let topic = NtfyTopic.getOrCreate()
        let server = NtfyTopic.server ?? "https://ntfy.sh"
        guard let url = URL(string: "\(server)/\(topic)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue("default", forHTTPHeaderField: "Priority")
        req.httpBody = Data(body.utf8)
        URLSession.shared.dataTask(with: req) { [weak self] _, _, err in
            if let err { self?.logger.error("ntfy failed: \(err.localizedDescription, privacy: .public)") }
        }.resume()
    }
}
