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

    var staleThreshold: TimeInterval = DoomCoderConstants.staleSessionThreshold
    var evictionDelay: TimeInterval  = DoomCoderConstants.evictionDelay

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
        var lastToolArgsPreview: String?
        var modelShortName: String?
        var lastSubagentType: String?
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
            if event.phase == .toolStart, let preview = event.toolArgsPreview {
                lastToolArgsPreview = preview
            }
            if let name = event.modelShortName { modelShortName = name }
            if let st = event.subagentType { lastSubagentType = st }

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
            case .sessionStart, .agentResponse, .userPrompt,
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

        publishToCloudKit(envelope: env, normalized: normalized, session: s, sessionKey: sessionKey, payloadString: payloadString)
        ApprovalCoordinator.shared.handleIfNeeded(envelope: env)

        // Notification dispatch — uses user-configurable phase preferences
        // Suppress sessionEnd notifications when the agent PID is dead — this
        // means the user already quit (Cmd+Q) before the final Stop/sessionEnd
        // hook arrived. Timeline entry is still recorded above.
        let isQuitInitiatedEnd = normalized.phase == .sessionEnd
            && !PIDLiveness.isAlive(pid_t(env.pid))
        let shouldNotify = NotificationPolicy.isNotifiable(phase: normalized.phase)
            && !isQuitInitiatedEnd
        logger.info("ingest agent=\(normalized.agent.rawValue, privacy: .public) event=\(normalized.rawEvent, privacy: .public) phase=\(normalized.phase.rawValue, privacy: .public) notify=\(shouldNotify) quitInitiated=\(isQuitInitiatedEnd)")
        if shouldNotify {
            NotificationRouter.shared.dispatch(.init(
                sessionKey: sessionKey, agent: normalized.agent,
                event: normalized.rawEvent, phase: normalized.phase
            ))
        }

        // Evict terminal sessions after configured delay
        if !s.isLive {
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

    // MARK: - CloudKit bridge

    private func publishToCloudKit(envelope env: HookEnvelope,
                                    normalized: NormalizedHookEvent,
                                    session s: Session,
                                    sessionKey: String,
                                    payloadString: String?) {
        guard FeatureFlags.cloudKitEnabled else { return }

        let now = normalized.timestamp
        let cwd = s.cwd
        let basename = (cwd as NSString).lastPathComponent
        let suffix = env.cwdHashSuffix ?? CloudKitHash.fnv1a6(cwd)
        let hostname = env.macHostname ?? ProcessInfo.processInfo.hostName
        let phase = env.hookPhase ?? normalized.phase.rawValue
        let expiresEvent = now.addingTimeInterval(7 * 24 * 3600)

        let event = CKAgentEvent(
            sessionKey: sessionKey,
            agent: normalized.agent.rawValue,
            agentVariant: env.agentVariant,
            macHostname: hostname,
            cwdBasename: basename,
            cwdHashSuffix: suffix,
            hookPhase: phase,
            occurredAt: now,
            payloadJSON: payloadString ?? "{}",
            expiresAt: expiresEvent
        )

        let status: CKSessionAggregate.Status = {
            if s.hasFailed { return .failed }
            if s.hasEnded { return .completed }
            if s.awaitingPermission { return .waitingApproval }
            return .running
        }()
        let filesEdited = (s.toolCounts["Edit"] ?? 0)
            + (s.toolCounts["Write"] ?? 0)
            + (s.toolCounts["MultiEdit"] ?? 0)

        let aggregate = CKSessionAggregate(
            sessionKey: sessionKey,
            agent: normalized.agent.rawValue,
            agentVariant: env.agentVariant,
            macHostname: hostname,
            cwdBasename: basename,
            cwdHashSuffix: suffix,
            startedAt: s.startedAt,
            lastEventAt: s.updatedAt,
            endedAt: s.hasEnded || s.hasFailed ? s.updatedAt : nil,
            status: status,
            currentTool: s.lastTool,
            totalToolCalls: s.toolCallCount,
            totalFilesEdited: filesEdited,
            totalErrors: s.errorCount,
            model: s.modelShortName,
            promptPreview: nil,
            toolArgsPreview: s.lastToolArgsPreview,
            expiresAt: s.updatedAt.addingTimeInterval(7 * 24 * 3600),
            pendingRequestId: status == .waitingApproval ? env.requestId : nil
        )

        CloudKitPublisher.shared.publish(event: event, aggregate: aggregate)
    }

}

// FNV-1a 32-bit hash → 6 hex chars (matches dc-hook cwdHashSuffix algorithm).
enum CloudKitHash {
    static func fnv1a6(_ s: String) -> String {
        var h: UInt32 = 2166136261
        for b in s.utf8 {
            h ^= UInt32(b)
            h = h &* 16777619
        }
        return String(format: "%06x", h & 0xFFFFFF)
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
