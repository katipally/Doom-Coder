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
    private let dedupeWindow: TimeInterval = 3

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
        if channels.ntfy {
            postNtfy(title: title, body: body)
            EventStore.shared.insertNotification(
                sessionKey: ev.sessionKey, agent: ev.agent.rawValue, event: ev.event,
                title: title, body: body, channel: "ntfy", success: true, ts: ts
            )
        }
    }

    /// FM-judge-sourced notification. Title and body come pre-formed from the
    /// on-device model; this bypasses the standard title/body copy templates.
    func dispatchFMJudge(title: String, body: String, urgency: String,
                          sessionKey: String, agent: TrackedAgent, event: String) {
        let masterEnabled = UserDefaults.standard.object(forKey: "doomcoder.masterEnabled") as? Bool ?? true
        guard masterEnabled, TrackingStore.isEnabled(agent) else { return }

        // Honor per-event prefs for FM-judge notifications (phase = "other" fallback).
        let prefs = ChannelStore.loadPrefs(for: agent)
        guard prefs.shouldNotify(rawEvent: event, phase: "other") else { return }

        let key = "\(sessionKey)::fm::\(title)::\(body)"
        if let last = lastDispatchAt[key], Date().timeIntervalSince(last) < dedupeWindow { return }
        lastDispatchAt[key] = Date()

        let channels = ChannelStore.effectiveChannels(for: agent)
        let ts = Date().timeIntervalSince1970

        if channels.macNotification {
            postLocal(title: title, body: body, threadID: sessionKey, agent: agent)
            EventStore.shared.insertNotification(
                sessionKey: sessionKey, agent: agent.rawValue, event: event,
                title: title, body: body, channel: "macOS(fm)", success: true, ts: ts
            )
        }
        if channels.ntfy {
            postNtfy(title: title, body: body)
            EventStore.shared.insertNotification(
                sessionKey: sessionKey, agent: agent.rawValue, event: event,
                title: title, body: body, channel: "ntfy(fm)", success: true, ts: ts
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
        let name = ev.agent.displayName
        switch ev.phase {
        case .sessionStart:    return "\(name) · started"
        case .sessionEnd:      return "\(name) · done"
        case .agentResponse:   return "\(name) · replied"
        case .error:           return "\(name) · error"
        case .toolError:       return "\(name) · tool failed"
        case .permissionNeeded:return "\(name) · needs you"
        case .subagentStart:   return "\(name) · sub-agent started"
        case .subagentEnd:     return "\(name) · sub-agent done"
        case .toolStart:       return "\(name) · running"
        case .toolEnd:         return "\(name) · tool done"
        case .fileChanged:     return "\(name) · edited a file"
        case .userPrompt:      return "\(name) · prompt received"
        case .other:
            // Use raw event name to produce a readable label when possible.
            return "\(name) · \(readableEventLabel(ev.event))"
        }
    }

    private func bodyFor(_ ev: Event) -> String {
        let session = AgentTrackingManager.shared.sessions[ev.sessionKey]
        let tool   = session?.lastTool.flatMap { $0.isEmpty ? nil : $0 }
        let folder = session.flatMap { shortCwd($0.cwd) }

        // Body = tool name when available, else project folder, else empty.
        // Keep it to one short token so the banner is scannable at a glance.
        switch ev.phase {
        case .toolStart, .toolEnd, .toolError, .error, .permissionNeeded:
            return tool ?? folder ?? ""
        case .sessionStart, .sessionEnd:
            return folder ?? ""
        case .agentResponse, .userPrompt, .subagentStart, .subagentEnd,
             .fileChanged, .other:
            return tool ?? folder ?? ""
        }
    }

    /// Converts a raw hook event name to a short readable label for use in titles.
    /// e.g. "afterAgentThought" → "thinking", "preCompact" → "compacting context"
    private func readableEventLabel(_ rawEvent: String) -> String {
        switch rawEvent {
        // Cursor
        case "afterAgentThought":     return "thinking"
        case "preCompact",
             "PreCompact":            return "compacting context"
        case "beforeSubmitPrompt":    return "submitting prompt"
        case "beforeTabFileRead":     return "reading file"
        case "afterTabFileEdit":      return "edited file"
        // Claude
        case "Notification":          return "notification"
        case "Elicitation":          return "waiting for input"
        case "ElicitationResult":    return "input received"
        case "TaskCreated":          return "task created"
        case "TaskCompleted":        return "task completed"
        case "PostCompact":          return "context compacted"
        case "ConfigChange":         return "config changed"
        case "InstructionsLoaded":   return "instructions loaded"
        case "FileChanged":          return "file changed"
        case "CwdChanged":           return "directory changed"
        case "WorktreeCreate":       return "worktree created"
        case "WorktreeRemove":       return "worktree removed"
        case "Setup":                return "setting up"
        case "UserPromptExpansion":  return "expanding prompt"
        case "PostToolBatch":        return "tool batch done"
        case "TeammateIdle":         return "teammate idle"
        // Windsurf
        case "pre_user_prompt":                      return "prompt incoming"
        case "post_setup_worktree":                  return "worktree ready"
        case "pre_read_code":                        return "reading code"
        case "post_read_code":                       return "code read"
        case "pre_write_code":                       return "writing code"
        case "post_write_code":                      return "code written"
        case "pre_run_command":                      return "running command"
        case "post_run_command":                     return "command done"
        case "post_mcp_tool_use":                    return "MCP tool done"
        // CopilotCLI
        case "userPromptSubmitted":                  return "prompt received"
        case "errorOccurred":                        return "error"
        // Generic fallback: camelCase/snake_case → spaced words
        default:
            let spaced = rawEvent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "([A-Z])", with: " $1",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return spaced.isEmpty ? rawEvent : spaced
        }
    }

    /// Short, human-friendly cwd label: "~/foo/bar" → "bar" (last path component).
    private func shortCwd(_ cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty ? nil : last
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
                   options: nil
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
