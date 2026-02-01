import Foundation
import Observation
import OSLog

// Central state machine. Consumes HookEnvelope from the socket listener,
// maintains per-session state, drives SleepManager auto-fuse, emits
// notifications, and persists events to the EventStore.
@Observable
@MainActor
final class AgentTrackingManager {
    static let shared = AgentTrackingManager()

    private let logger = Logger(subsystem: "com.doomcoder", category: "agents")

    struct Session: Identifiable, Sendable {
        let id: String          // session key
        let agent: TrackedAgent
        var state: AgentSessionState
        var lastEvent: String
        var toolCounts: [String: Int] = [:]
        var lastTool: String?
        var cwd: String
        var startedAt: Date
        var updatedAt: Date
    }

    private(set) var sessions: [String: Session] = [:]
    var liveSessions: [Session] { sessions.values.filter {
        $0.state == .running || $0.state == .waitingInput || $0.state == .waitingApproval
    }.sorted { $0.updatedAt > $1.updatedAt } }

    private weak var sleepManager: SleepManager?

    func bind(sleepManager: SleepManager) { self.sleepManager = sleepManager }

    // MARK: - Entry point (called from socket listener)

    func ingest(_ env: HookEnvelope) {
        guard !PauseFlag.isPaused else { return }
        guard let agent = TrackedAgent(rawValue: env.agent) else {
            logger.debug("unknown agent \(env.agent, privacy: .public)")
            return
        }
        let payload = env.payloadDict ?? [:]
        let sessionKey = Self.sessionKey(agent: agent, env: env, payload: payload)
        let tool = payload["tool_name"] as? String ?? payload["tool"] as? String
        let path = payload["cwd"] as? String ?? env.cwd

        let newState = Self.deriveState(agent: agent, event: env.event, payload: payload)
        var s = sessions[sessionKey] ?? Session(
            id: sessionKey,
            agent: agent,
            state: .running,
            lastEvent: env.event,
            cwd: path,
            startedAt: Date(),
            updatedAt: Date()
        )
        let previous = s.state
        s.state = newState
        s.lastEvent = env.event
        s.updatedAt = Date()
        if let tool {
            s.toolCounts[tool, default: 0] += 1
            s.lastTool = tool
        }
        sessions[sessionKey] = s

        EventStore.shared.insert(
            sessionKey: sessionKey, agent: agent.rawValue, event: env.event,
            tool: tool, path: path, state: newState.rawValue, ts: env.ts
        )

        updateAutoFuse()
        if shouldNotify(previous: previous, current: newState, event: env.event) {
            NotificationDispatcher.shared.dispatch(.init(
                sessionKey: sessionKey, agent: agent, state: newState
            ))
        }

        if newState == .completed || newState == .failed {
            // Keep terminal sessions around briefly so the popover can show them,
            // then evict after 10 minutes.
            Task { [sessionKey] in
                try? await Task.sleep(for: .seconds(600))
                await MainActor.run {
                    if let cur = self.sessions[sessionKey],
                       cur.state == .completed || cur.state == .failed {
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

    // MARK: - Notification policy

    private func shouldNotify(previous: AgentSessionState, current: AgentSessionState, event: String) -> Bool {
        if previous == current { return false }
        switch current {
        case .running:           return previous == .waitingInput || previous == .waitingApproval || event.lowercased().contains("sessionstart")
        case .waitingInput:      return true
        case .waitingApproval:   return true
        case .completed:         return true
        case .failed:            return true
        }
    }

    // MARK: - Event → state mapping

    private static func deriveState(agent: TrackedAgent, event: String, payload: [String: Any]) -> AgentSessionState {
        let e = event
        switch agent {
        case .claude:
            if e == "SessionStart" { return .running }
            if e == "Notification" {
                let t = (payload["notification_type"] as? String) ?? (payload["type"] as? String) ?? ""
                if t.contains("permission") { return .waitingApproval }
                return .waitingInput
            }
            if e == "Stop" || e == "SubagentStop" { return .completed }
        case .cursor:
            if e == "sessionStart" { return .running }
            if e == "afterAgentResponse" { return .waitingInput }
            if e == "stop" { return .completed }
        case .vscode:
            if e == "sessionStart" { return .running }
            if e == "notification" { return .waitingInput }
            if e == "sessionEnd" || e == "stop" { return .completed }
        case .copilotCLI:
            if e == "sessionStart" { return .running }
            if e == "userPromptSubmitted" { return .running }
            if e == "errorOccurred" { return .failed }
            if e == "sessionEnd" { return .completed }
        }
        return .running
    }

    private static func sessionKey(agent: TrackedAgent, env: HookEnvelope, payload: [String: Any]) -> String {
        let sid = (payload["session_id"] as? String)
            ?? (payload["sessionId"] as? String)
            ?? (payload["session"] as? String)
            ?? "pid-\(env.pid)"
        return "\(agent.rawValue)::\(sid)"
    }
}
