import Foundation
import Observation
import OSLog

// Central event hub. Consumes HookEnvelope from the socket listener,
// maintains per-session raw event timelines, drives SleepManager auto-fuse,
// emits notifications for milestone events, and persists to EventStore.
@Observable
@MainActor
final class AgentTrackingManager {
    static let shared = AgentTrackingManager()

    private let logger = Logger(subsystem: "com.doomcoder", category: "agents")

    struct Session: Identifiable, Sendable {
        let id: String          // session key
        let agent: TrackedAgent
        var events: [TimelineEvent] = []
        var lastEvent: String
        var toolCounts: [String: Int] = [:]
        var lastTool: String?
        var cwd: String
        var startedAt: Date
        var updatedAt: Date

        /// Whether the session is still active.
        var isLive: Bool { !NotificationPolicy.isTerminal(event: lastEvent) }

        /// Human-readable status derived from the latest event.
        var status: String {
            humanReadable(for: lastEvent)
        }

        /// Color-friendly category (for the UI's stateColor helper).
        var displayState: AgentSessionState {
            Self.stateFromEvent(lastEvent)
        }

        private func humanReadable(for event: String) -> String {
            let e = event.lowercased()
            if e.contains("sessionstart") { return "running" }
            if e.contains("sessionend") || e.contains("stop") || e == "taskcompleted" { return "completed" }
            if e.contains("error") || e.contains("failure") { return "failed" }
            if e.contains("permission") { return "waiting for approval" }
            if e.contains("notification") || e.contains("elicitation") { return "waiting for input" }
            if e.contains("afteragentresponse") { return "waiting for input" }
            return "running"
        }

        static func stateFromEvent(_ event: String) -> AgentSessionState {
            let e = event.lowercased()
            if e.contains("sessionend") || e.contains("stop") || e == "taskcompleted" { return .completed }
            if e.contains("error") || e.contains("failure") { return .failed }
            if e.contains("permission") { return .waitingApproval }
            if e.contains("notification") || e.contains("elicitation") || e.contains("afteragentresponse") { return .waitingInput }
            return .running
        }
    }

    private(set) var sessions: [String: Session] = [:]
    var liveSessions: [Session] { sessions.values.filter(\.isLive).sorted { $0.updatedAt > $1.updatedAt } }

    private weak var sleepManager: SleepManager?

    func bind(sleepManager: SleepManager) { self.sleepManager = sleepManager }

    // MARK: - Entry point (called from socket listener)

    func ingest(_ env: HookEnvelope) {
        let pausedBefore = PauseFlag.isPaused
        logger.info("socket recv agent=\(env.agent, privacy: .public) event=\(env.event, privacy: .public) synthetic=\(env.synthetic) paused=\(pausedBefore)")
        guard !pausedBefore else {
            logger.info("drop: pause flag set (agent=\(env.agent, privacy: .public))")
            return
        }
        guard let agent = TrackedAgent(rawValue: env.agent) else {
            logger.notice("drop: unknown agent \(env.agent, privacy: .public)")
            return
        }
        let payload = env.payloadDict ?? [:]
        let sessionKey = Self.sessionKey(agent: agent, env: env, payload: payload)
        let tool = payload["tool_name"] as? String ?? payload["tool"] as? String
        let path = payload["cwd"] as? String ?? env.cwd

        // Build timeline entry
        let summary = Self.buildSummary(event: env.event, tool: tool, payload: payload)
        let timelineEvent = TimelineEvent(
            event: env.event,
            tool: tool,
            path: path,
            timestamp: Date(timeIntervalSince1970: env.ts),
            summary: summary
        )

        var s = sessions[sessionKey] ?? Session(
            id: sessionKey,
            agent: agent,
            lastEvent: env.event,
            cwd: path,
            startedAt: Date(),
            updatedAt: Date()
        )
        s.events.append(timelineEvent)
        s.lastEvent = env.event
        s.updatedAt = Date()
        if let tool {
            s.toolCounts[tool, default: 0] += 1
            s.lastTool = tool
        }
        sessions[sessionKey] = s

        // Persist to SQLite (with raw JSON payload for Logs detail view)
        let payloadString: String?
        if let raw = env.payloadRaw {
            payloadString = String(data: raw, encoding: .utf8)
        } else {
            payloadString = nil
        }
        EventStore.shared.insert(
            sessionKey: sessionKey, agent: agent.rawValue, event: env.event,
            tool: tool, path: path, state: env.event, ts: env.ts,
            payload: payloadString
        )

        updateAutoFuse()

        // Notification dispatch — only for milestone events
        let shouldNotify = NotificationPolicy.isNotifiable(agent: agent, event: env.event)
        logger.info("ingest agent=\(agent.rawValue, privacy: .public) event=\(env.event, privacy: .public) notify=\(shouldNotify)")
        if shouldNotify {
            NotificationDispatcher.shared.dispatch(.init(
                sessionKey: sessionKey, agent: agent, event: env.event
            ))
        }

        // Evict terminal sessions after 10 minutes
        if NotificationPolicy.isTerminal(event: env.event) {
            Task { [sessionKey] in
                try? await Task.sleep(for: .seconds(600))
                await MainActor.run {
                    if let cur = self.sessions[sessionKey], !cur.isLive {
                        self.sessions.removeValue(forKey: sessionKey)
                        self.updateAutoFuse()
                    }
                }
            }
        }
    }

    // MARK: - Auto-fuse

    private func updateAutoFuse() {
        let autoFuseEnabled = UserDefaults.standard.object(forKey: "doomcoder.agents.autoFuse") as? Bool ?? true
        guard autoFuseEnabled else {
            sleepManager?.releaseAgentFuse()
            return
        }
        let live = !liveSessions.isEmpty
        if live {
            sleepManager?.forceScreenOn(reason: "Tracking \(liveSessions.count) agent session(s)")
        } else {
            sleepManager?.releaseAgentFuse()
        }
    }

    // MARK: - Session key extraction

    private static func sessionKey(agent: TrackedAgent, env: HookEnvelope, payload: [String: Any]) -> String {
        // Try all known session-id field names across agents.
        let sid = (payload["session_id"] as? String)
            ?? (payload["sessionId"] as? String)
            ?? (payload["session"] as? String)
            ?? (payload["conversation_id"] as? String)    // Cursor
            ?? (payload["generation_id"] as? String)
            ?? "pid-\(env.pid)"                            // uses parent PID from dc-hook
        return "\(agent.rawValue)::\(sid)"
    }

    // MARK: - Summary builder

    private static func buildSummary(event: String, tool: String?, payload: [String: Any]) -> String {
        if let tool {
            let filePath = (payload["file_path"] as? String) ?? (payload["input"] as? [String: Any])?["file_path"] as? String
            if let filePath {
                return "\(tool): \(URL(fileURLWithPath: filePath).lastPathComponent)"
            }
            return tool
        }
        // Fall back to a short description of the event
        return event
    }
}

// Kept for backward compatibility with UI code (stateColor helpers).
enum AgentSessionState: String, Sendable {
    case running
    case waitingInput     = "waiting_input"
    case waitingApproval  = "waiting_approval"
    case completed
    case failed

    var humanReadable: String {
        switch self {
        case .running:          return "running"
        case .waitingInput:     return "waiting for input"
        case .waitingApproval:  return "waiting for approval"
        case .completed:        return "completed"
        case .failed:           return "failed"
        }
    }
}
