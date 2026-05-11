import Foundation
import UserNotifications
import AppKit
import OSLog

// Fan-out for DoomCoder agent notifications. Honors the TrackingStore
// per-agent opt-out and the global ChannelStore (macOS local + ntfy).
// Minimal content only — no prompt text, no file paths over ntfy. 5-second
// dedupe window per (session, event).
@MainActor
@Observable
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
        let event: String                   // raw event name from the hook
        let phase: NormalizedEventPhase?    // nil only for synthetic events (e.g. inferredWaiting)
    }

    func dispatch(_ ev: Event) {
        // Master switch off → fully suppress all notifications. Hook socket
        // keeps running, live events still update the UI; only outbound
        // alerts are muted until the user re-enables DoomCoder.
        let masterEnabled = UserDefaults.standard.object(forKey: "doomcoder.masterEnabled") as? Bool ?? true
        guard masterEnabled else { return }

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
            postLocal(title: title, body: body, threadID: ev.sessionKey, agent: ev.agent)
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
            postLocal(title: "DoomCoder", body: "macOS notifications are working ✨", threadID: "test")
            return true
        case .ntfy:
            postNtfy(title: "DoomCoder", body: "ntfy channel is working ✨")
            return true
        }
    }

    enum TestChannel { case macOS, ntfy }

    // MARK: - Copy

    private func titleFor(_ ev: Event) -> String {
        // Synthetic inferred-waiting bypasses the normalizer — handle by name.
        if ev.event == "inferredWaiting" { return "DoomCoder · check in" }
        switch ev.phase {
        case .sessionStart:                 return "DoomCoder · started"
        case .sessionEnd:                   return "DoomCoder · done"
        case .error, .toolError:            return "DoomCoder · failed"
        case .permissionNeeded:             return "DoomCoder · needs you"
        default:                            return "DoomCoder"
        }
    }

    private func bodyFor(_ ev: Event) -> String {
        let name = ev.agent.displayName

        // Synthetic inferred-waiting (60s timeout) — distinct phrasing.
        if ev.event == "inferredWaiting" {
            return "\(name) — may need your attention"
        }

        switch ev.phase {
        case .sessionStart:
            return name

        case .sessionEnd:
            let duration = sessionDuration(for: ev.sessionKey)
            return duration.map { "\(name) — done  ·  \($0)" } ?? "\(name) — done"

        case .error, .toolError:
            let duration = sessionDuration(for: ev.sessionKey)
            return duration.map { "\(name) — failed  ·  \($0)" } ?? "\(name) — failed"

        case .permissionNeeded:
            return "\(name) — needs you"

        default:
            return name
        }
    }

    /// Looks up the session in AgentTrackingManager and formats elapsed time since start.
    private func sessionDuration(for sessionKey: String) -> String? {
        guard let session = AgentTrackingManager.shared.sessions[sessionKey] else { return nil }
        let elapsed = Date().timeIntervalSince(session.startedAt)
        guard elapsed > 1 else { return nil }
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    // MARK: - macOS local
    //
    // Posts are serialised through a single serial DispatchQueue with a tiny
    // stagger between each. Without this, UNUserNotificationCenter can
    // reorder bursts of notifications (the banner queue sorts by scheduled
    // delivery time, which for immediate triggers can collapse to the same
    // millisecond and produce reversed order). `threadIdentifier` groups
    // notifications from the same agent session in Notification Center.
    nonisolated private static let notifyQueue = DispatchQueue(
        label: "com.doomcoder.notify.serial",
        qos: .userInitiated
    )

    private func postLocal(title: String, body: String, threadID: String, agent: TrackedAgent? = nil) {
        let logger = self.logger
        let iconURL = agent.flatMap { AgentIconProvider.iconFileURL(for: $0) }
        Self.notifyQueue.async {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = threadID
            // Attach agent icon as notification thumbnail if available.
            if let iconURL,
               let attachment = try? UNNotificationAttachment(
                   identifier: "agent-icon",
                   url: iconURL,
                   options: [UNNotificationAttachmentOptionsThumbnailClippingRectKey:
                               CGRect(x: 0, y: 0, width: 1, height: 1) as AnyObject]
               ) {
                content.attachments = [attachment]
            }
            // A tiny 10ms trigger preserves enqueue order vs. immediate nil
            // triggers, which UN can collapse to the same delivery slot.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.01, repeats: false)
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(req) { err in
                if let err {
                    Task { @MainActor in
                        logger.error("local notify failed: \(err.localizedDescription, privacy: .public)")
                    }
                }
            }
            // 50 ms stagger between posts so macOS preserves our enqueue
            // order even under rapid bursts (session start → tool call →
            // session end arriving within the same runloop tick).
            Thread.sleep(forTimeInterval: 0.05)
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
