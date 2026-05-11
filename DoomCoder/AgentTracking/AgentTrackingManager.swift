import Foundation
import Observation
import OSLog
import SwiftUI

// Central event hub. Consumes HookEnvelope from the socket listener,
// normalizes via per-agent normalizers, maintains SessionAggregate
// instances with counters/flags, emits notifications for milestone
// events, and persists raw events to EventStore.
@Observable
@MainActor
final class AgentTrackingManager {
    static let shared = AgentTrackingManager()

    private let logger = Logger(subsystem: "com.doomcoder", category: "agents")

    /// Stale threshold: sessions with no events for this long are considered stale.
    var staleThreshold: TimeInterval = 900  // 15 minutes

    /// Auto-eviction delay after a session reaches terminal state.
    var evictionDelay: TimeInterval = 1800  // 30 minutes

    // MARK: - Session aggregate model

    /// Aggregate model that tracks counters/flags instead of doing naive
    /// string matching. Derives UI state from the accumulated data.
    struct Session: Identifiable, Sendable {
        let id: String              // agent::sessionId
        let agent: TrackedAgent
        let sessionId: String
        var events: [TimelineEvent] = []
        var lastEvent: String
        var lastPhase: NormalizedEventPhase = .sessionStart
        var toolCounts: [String: Int] = [:]
        var lastTool: String?
        var cwd: String
        var startedAt: Date
        var updatedAt: Date

        // Counters
        var toolCallCount: Int = 0
        var activeToolCount: Int = 0
        var errorCount: Int = 0
        var subagentCount: Int = 0

        // Flags
        var awaitingPermission: Bool = false
        var hasEnded: Bool = false
        var hasFailed: Bool = false

        /// Whether the session is still active (not terminal).
        var isLive: Bool { !hasEnded && !hasFailed }

        /// Human-readable status derived from the aggregate state.
        var status: String { displayState.humanReadable }

        /// Color-friendly UI state derived from counters/flags.
        var displayState: AgentSessionState {
            if hasFailed { return .failed }
            if hasEnded { return .completed }
            if awaitingPermission { return .waitingApproval }
            if lastPhase == .agentResponse { return .waitingInput }
            return .running
        }

        /// Check if session is stale (no events for too long).
        func isStale(threshold: TimeInterval) -> Bool {
            !hasEnded && !hasFailed && Date().timeIntervalSince(updatedAt) > threshold
        }

        // MARK: - Apply normalized event

        mutating func apply(_ event: NormalizedHookEvent) {
            lastEvent = event.rawEvent
            lastPhase = event.phase
            updatedAt = event.timestamp
            if let tool = event.toolName {
                toolCounts[tool, default: 0] += 1
                lastTool = tool
            }

            switch event.phase {
            case .toolStart:
                activeToolCount += 1
            case .toolEnd:
                activeToolCount = max(0, activeToolCount - 1)
                toolCallCount += 1
            case .toolError:
                activeToolCount = max(0, activeToolCount - 1)
                toolCallCount += 1
                errorCount += 1
            case .permissionNeeded:
                awaitingPermission = true
            case .sessionEnd:
                hasEnded = true
            case .error:
                errorCount += 1
                if event.isFatal { hasFailed = true }
            case .subagentStart:
                subagentCount += 1
            case .subagentEnd:
                subagentCount = max(0, subagentCount - 1)
            case .sessionStart, .userPrompt, .agentResponse,
                 .fileChanged, .other:
                break
            }

            // Clear permission flag when work resumes after permission grant
            if awaitingPermission && (event.phase == .toolStart || event.phase == .userPrompt) {
                awaitingPermission = false
            }
        }
    }

    private(set) var sessions: [String: Session] = [:]
    var liveSessions: [Session] { sessions.values.filter(\.isLive).sorted { $0.updatedAt > $1.updatedAt } }

    // 60-second inference timers: fire a "may need your attention" notification when
    // a toolStart has no matching toolEnd/toolError within the window. Applied only
    // to agents without explicit permission hooks (all agents except Claude Code).
    private var waitTimers: [String: Task<Void, Never>] = [:]
    private static let waitInferenceAgents: Set<TrackedAgent> = [.cursor, .vscode, .copilotCLI, .windsurf]
    private static let waitInferenceSeconds: TimeInterval = 60

    // MARK: - Entry point (called from socket listener)

    func ingest(_ env: HookEnvelope) {
        let pausedBefore = PauseFlag.isPaused
        logger.info("socket recv agent=\(env.agent, privacy: .public) event=\(env.event, privacy: .public) synthetic=\(env.synthetic) paused=\(pausedBefore)")
        guard !pausedBefore else {
            logger.info("drop: pause flag set (agent=\(env.agent, privacy: .public))")
            return
        }

        // Always capture raw envelope for Live Events — even if normalization fails.
        LiveEventsStore.shared.append(env)

        // Normalize via per-agent normalizer
        guard let normalized = EventNormalizerRegistry.normalize(envelope: env) else {
            logger.notice("drop: normalization failed for agent=\(env.agent, privacy: .public) event=\(env.event, privacy: .public)")
            return
        }

        let sessionKey = "\(normalized.agent.rawValue)::\(normalized.sessionId)"

        // Build timeline entry (raw event log)
        let timelineEvent = TimelineEvent(
            event: normalized.rawEvent,
            tool: normalized.toolName,
            path: normalized.filePath ?? normalized.cwd,
            timestamp: normalized.timestamp,
            summary: normalized.summary
        )

        let isNewSession = sessions[sessionKey] == nil
        var s = sessions[sessionKey] ?? Session(
            id: sessionKey,
            agent: normalized.agent,
            sessionId: normalized.sessionId,
            lastEvent: normalized.rawEvent,
            cwd: normalized.cwd,
            startedAt: normalized.timestamp,
            updatedAt: normalized.timestamp
        )
        s.events.append(timelineEvent)
        s.apply(normalized)

        // Assign without wrapping in withAnimation. Animation is applied at
        // the view layer via .animation(value:) on the sessions list, which
        // is safer than driving SwiftUI transactions from a socket-delivered
        // mutation (prior approach risked NSHostingView constraint loops when
        // hosted under MenuBarExtra(.window)).
        _ = isNewSession
        sessions[sessionKey] = s

        // Persist to SQLite (with raw JSON payload for Logs detail view)
        let payloadString: String?
        if let raw = env.payloadRaw {
            payloadString = String(data: raw, encoding: .utf8)
        } else {
            payloadString = nil
        }
        EventStore.shared.insert(
            sessionKey: sessionKey, agent: normalized.agent.rawValue,
            event: normalized.rawEvent,
            tool: normalized.toolName, path: normalized.cwd,
            state: normalized.phase.rawValue, ts: env.ts,
            payload: payloadString
        )

        // Notification dispatch — uses user-configurable phase preferences
        let shouldNotify = NotificationPolicy.isNotifiable(phase: normalized.phase)
        logger.info("ingest agent=\(normalized.agent.rawValue, privacy: .public) event=\(normalized.rawEvent, privacy: .public) phase=\(normalized.phase.rawValue, privacy: .public) notify=\(shouldNotify)")
        if shouldNotify {
            NotificationDispatcher.shared.dispatch(.init(
                sessionKey: sessionKey, agent: normalized.agent,
                event: normalized.rawEvent, phase: normalized.phase
            ))
        }

        // 60s waiting inference for agents without explicit permission hooks.
        // Start a timer on toolStart, cancel it when the tool resolves.
        if Self.waitInferenceAgents.contains(normalized.agent) {
            switch normalized.phase {
            case .toolStart:
                startWaitInferenceTimer(sessionKey: sessionKey, agent: normalized.agent)
            case .toolEnd, .toolError, .sessionEnd, .error:
                cancelWaitInferenceTimer(sessionKey: sessionKey)
            default:
                break
            }
        }

        // Evict terminal sessions after configured delay
        if !s.isLive {
            cancelWaitInferenceTimer(sessionKey: sessionKey)
            let delay = evictionDelay
            Task { [sessionKey] in
                try? await Task.sleep(for: .seconds(delay))
                await MainActor.run {
                    if let cur = self.sessions[sessionKey], !cur.isLive {
                        self.sessions.removeValue(forKey: sessionKey)
                    }
                }
            }
        }
    }

    // MARK: - Wait inference timer

    private func startWaitInferenceTimer(sessionKey: String, agent: TrackedAgent) {
        // Cancel any existing timer for this session (re-arm on each tool call)
        waitTimers[sessionKey]?.cancel()
        let delay = Self.waitInferenceSeconds
        waitTimers[sessionKey] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // Only fire if the session is still live (not ended/failed)
                guard let session = self.sessions[sessionKey], session.isLive else { return }
                self.logger.info("wait-inference fired sessionKey=\(sessionKey, privacy: .public)")
                self.waitTimers.removeValue(forKey: sessionKey)
                // Dispatch inferred-waiting notification
                NotificationDispatcher.shared.dispatch(.init(
                    sessionKey: sessionKey, agent: agent,
                    event: "inferredWaiting", phase: nil
                ))
            }
        }
    }

    private func cancelWaitInferenceTimer(sessionKey: String) {
        waitTimers[sessionKey]?.cancel()
        waitTimers.removeValue(forKey: sessionKey)
    }
}

// UI state enum — derived from SessionAggregate counters/flags.
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
