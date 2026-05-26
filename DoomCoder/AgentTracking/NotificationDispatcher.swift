import Foundation
import UserNotifications
import AppKit
import OSLog
import DoomCoderCore

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
    private let dedupeWindow: TimeInterval = 10

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
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Public dispatch

    struct Event: Sendable {
        let sessionKey: String
        let agent: TrackedAgent
        let event: String                   // raw event name from the hook
        let phase: NormalizedEventPhase
    }

    func dispatch(_ ev: Event) {
        // Master switch off → fully suppress all notifications. Hook socket
        // keeps running, live events still update the UI; only outbound
        // alerts are muted until the user re-enables DoomCoder.
        let masterEnabled = UserDefaults.standard.object(forKey: "doomcoder.masterEnabled") as? Bool ?? true
        guard masterEnabled else { return }

        // Honor per-agent Tracking toggle (user opted this agent out).
        guard TrackingStore.isEnabled(ev.agent) else { return }

        // Per-agent burst protection. Prevents tight-loop storms from a stuck
        // agent. Emits at most one informational notif per depleted window.
        switch RateLimiter.shared.evaluate(agent: ev.agent) {
        case .allow:
            break
        case .dropped(let emitWarning):
            if emitWarning {
                postLocal(
                    title: "DoomCoder · rate-limited",
                    body: "Throttling \(ev.agent.displayName) notifications — too many in a short time.",
                    threadID: "ratelimit::\(ev.agent.rawValue)",
                    agent: ev.agent
                )
            }
            return
        }

        // Compute display content BEFORE building the dedup key.
        // Claude Code fires both PreToolUse and Notification hooks for the same
        // permission prompt — different raw event names but identical title + body.
        // Keying on rendered content collapses them into a single dispatch.
        let title = titleFor(ev)
        let body  = bodyFor(ev)
        let key = "\(ev.sessionKey)::\(ev.phase.rawValue)::\(title)::\(body)"
        if let last = lastDispatchAt[key], Date().timeIntervalSince(last) < dedupeWindow {
            return
        }
        lastDispatchAt[key] = Date()

        // Prune stale entries to prevent unbounded dictionary growth across long sessions.
        if lastDispatchAt.count > 100 {
            let staleThreshold = dedupeWindow * 8
            lastDispatchAt = lastDispatchAt.filter { Date().timeIntervalSince($0.value) < staleThreshold }
        }
        let channels = ChannelStore.effectiveChannels(for: ev.agent)
        let ts = Date().timeIntervalSince1970

        if channels.macNotification {
            postLocal(title: title, body: body, threadID: ev.sessionKey, agent: ev.agent)
            EventStore.shared.insertNotification(
                sessionKey: ev.sessionKey, agent: ev.agent.rawValue, event: ev.event,
                title: title, body: body, channel: "macOS", success: true, ts: ts
            )
        }
        if channels.cloudkit {
            postCloudKit(ev: ev, title: title, body: body)
            EventStore.shared.insertNotification(
                sessionKey: ev.sessionKey, agent: ev.agent.rawValue, event: ev.event,
                title: title, body: body, channel: "iOS", success: true, ts: ts
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
        case .cloudKit:
            postCloudKit(ev: nil, title: "DoomCoder", body: "iPhone push channel is working ✨")
            return true
        }
    }

    enum TestChannel { case macOS, cloudKit }

    // MARK: - Copy

    private func titleFor(_ ev: Event) -> String {
        let name = ev.agent.displayName
        switch ev.phase {
        case .sessionStart:                 return "\(name) · started"
        case .sessionEnd:                   return "\(name) · done"
        case .error, .toolError:            return "\(name) · failed"
        case .permissionNeeded:             return "\(name) · needs you"
        default:                            return name
        }
    }

    private func bodyFor(_ ev: Event) -> String {
        let session = AgentTrackingManager.shared.sessions[ev.sessionKey]
        let cwdLabel = session.flatMap { shortCwd($0.cwd) }
        let lastTool = session?.lastTool
        let duration = sessionDuration(for: ev.sessionKey)

        switch ev.phase {
        case .sessionStart:
            return cwdLabel.map { "Started in \($0)" } ?? "Started"

        case .sessionEnd:
            // Prefer "finished editing <file>" when a recent file edit is known,
            // else "finished using <tool>", else just duration.
            if let tool = lastTool, !tool.isEmpty {
                return duration.map { "Finished using \(tool) · \($0)" } ?? "Finished using \(tool)"
            }
            if let cwd = cwdLabel {
                return duration.map { "Finished in \(cwd) · \($0)" } ?? "Finished in \(cwd)"
            }
            return duration.map { "Finished · \($0)" } ?? "Finished"

        case .error, .toolError:
            if let tool = lastTool, !tool.isEmpty {
                return duration.map { "Failed in \(tool) · \($0)" } ?? "Failed in \(tool)"
            }
            return duration.map { "Failed · \($0)" } ?? "Failed"

        case .permissionNeeded:
            if let tool = lastTool, !tool.isEmpty {
                if tool == "ask_user"       { return "Has a question for you" }
                if tool == "exit_plan_mode" { return "Needs plan approval" }
                return "Waiting for your approval · \(tool)"
            }
            return "Waiting for your approval"

        default:
            return ev.agent.displayName
        }
    }

    /// Short, human-friendly cwd label: "~/foo/bar" → "bar" (last path component).
    private func shortCwd(_ cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty ? nil : last
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
            // 20 ms stagger between posts so macOS preserves our enqueue
            // order even under rapid bursts (session start → tool call →
            // session end arriving within the same runloop tick).
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    // MARK: - CloudKit (iOS companion push)

    private func postCloudKit(ev: Event?, title: String, body: String) {
        let pusher = CloudKitPusher.shared
        let session = ev.flatMap { AgentTrackingManager.shared.sessions[$0.sessionKey] }
        let rec = NotificationLogRecord(
            sessionKey: ev?.sessionKey ?? "test",
            macId: pusher.macId,
            macName: pusher.macName,
            agent: ev?.agent.rawValue ?? "doomcoder",
            phase: ev?.phase.rawValue ?? "test",
            rawEvent: ev?.event ?? "test",
            title: title,
            body: body,
            channel: "iOS",
            success: true,
            ts: Date(),
            lastTool: session?.lastTool,
            cwdBase: session.flatMap { shortCwd($0.cwd) }
        )
        pusher.publishNotificationLog(rec)
    }
}
