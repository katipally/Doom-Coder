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

    /// Auto-eviction delay: sessions with no events for this long are
    /// dropped from the in-memory map. Periodically swept every 60 s.
    var evictionDelay: TimeInterval = 1800  // 30 minutes

    /// Default delay (seconds) before completed/failed sessions auto-revert
    /// to idle. Overridable via UserDefaults "doomcoder.session.autoRevertSeconds".
    private let defaultAutoRevertSeconds: TimeInterval = 30

    /// User-configurable auto-revert delay; clamped to [10, 120].
    var autoRevertSeconds: TimeInterval {
        let raw = UserDefaults.standard.object(forKey: "doomcoder.session.autoRevertSeconds") as? Int
        let value = TimeInterval(raw ?? Int(defaultAutoRevertSeconds))
        return min(max(value, 10), 120)
    }

    /// Per-session monotonic token used to invalidate prior auto-revert timers
    /// when a new terminal event re-schedules.
    private var revertTokens: [String: Int] = [:]

    /// Process monitor for IDE open/close and CLI running detection.
    let processMonitor = AgentProcessMonitor.shared

    // MARK: - Session aggregate model

    /// Aggregate model that tracks counters/flags instead of doing naive
    /// string matching. Derives UI state from the accumulated data.
    struct Session: Identifiable, Sendable {
        let id: String              // agent::sessionId
        let agent: TrackedAgent
        let sessionId: String
        var lastEvent: String
        var lastPhase: NormalizedEventPhase = .sessionStart
        var toolCounts: [String: Int] = [:]
        var lastTool: String?
        var cwd: String
        var startedAt: Date
        var updatedAt: Date
        /// Last reported OS process id for this session. Meaningful only for
        /// CLI agents (they spawn dc-hook directly); IDE agents report a
        /// throwaway shell pid, so liveness must not be inferred from it.
        var pid: pid_t = 0

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
            switch lastPhase {
            case .sessionStart, .sessionEnd: return .open
            default: return .running
            }
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
            case .sessionStart, .agentResponse, .userPrompt,
                 .fileEdit, .compaction, .thinking, .housekeeping,
                 .other:
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

    /// Monotonic counter stamped on every ingested event. Used by
    /// `ApprovalArbiter` for "arrived after the permission request" reasoning
    /// (hook timestamps are cross-process and skewed, so they can't be trusted
    /// for ordering).
    private var ingestSeq: Int = 0

    private init() {
        // Periodic eviction sweep: drop sessions whose updatedAt is older than evictionDelay.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sweepEvictedSessions() }
        }
    }

    // MARK: - Session lifecycle helpers

    /// Called by PIDWatcher when a watched agent process exits without a
    /// terminal hook event. Treats process death as session completion so
    /// the badge transitions through completed -> idle via auto-revert.
    func finalizeOnPIDExit(sessionKey: String) {
        guard var s = sessions[sessionKey], s.isLive else { return }
        s.hasEnded = true
        s.updatedAt = Date()
        sessions[sessionKey] = s
        // Process is gone — drop any deferred approval alert for it.
        ApprovalArbiter.shared.clear(sessionKey: sessionKey)
        NotificationCenter.default.post(name: .doomcoderNewEvent, object: nil)
        scheduleTerminalRevert(sessionKey: sessionKey)
    }

    private func sweepEvictedSessions() {
        var changed = false
        let now = Date()
        for key in sessions.keys {
            guard let s = sessions[key] else { continue }
            guard now.timeIntervalSince(s.updatedAt) > evictionDelay else { continue }
            // Never evict a live CLI session whose process is still alive: a
            // long-running CLI agent can run quietly (no hook events) for well
            // over evictionDelay. Evicting it would drop activeAgentCount and
            // let the Mac sleep mid-task. PIDWatcher flips it terminal on exit.
            if s.isLive, !s.agent.isIDEAgent, s.pid > 0, PIDLiveness.isAlive(s.pid) {
                continue
            }
            sessions.removeValue(forKey: key)
            revertTokens.removeValue(forKey: key)
            ApprovalArbiter.shared.clear(sessionKey: key)
            changed = true
        }
        if changed { NotificationCenter.default.post(name: .doomcoderNewEvent, object: nil) }
    }

    /// Schedules a one-shot demotion of a completed/failed session back to
    /// idle (.open). If a newer event re-schedules, the older timer is
    /// invalidated via per-session monotonic token.
    func scheduleTerminalRevert(sessionKey: String) {
        let nextToken = (revertTokens[sessionKey] ?? 0) + 1
        revertTokens[sessionKey] = nextToken
        let delay = autoRevertSeconds
        Task { [sessionKey, nextToken] in
            try? await Task.sleep(for: .seconds(delay))
            await MainActor.run {
                guard self.revertTokens[sessionKey] == nextToken else { return }
                guard var s = self.sessions[sessionKey] else { return }
                guard s.hasEnded || s.hasFailed else { return }
                s.hasEnded = false
                s.hasFailed = false
                s.lastPhase = .sessionStart
                self.sessions[sessionKey] = s
                NotificationCenter.default.post(name: .doomcoderNewEvent, object: nil)
            }
        }
    }

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

        var s = sessions[sessionKey] ?? Session(
            id: sessionKey,
            agent: normalized.agent,
            sessionId: normalized.sessionId,
            lastEvent: normalized.rawEvent,
            cwd: normalized.cwd,
            startedAt: normalized.timestamp,
            updatedAt: normalized.timestamp
        )
        s.apply(normalized)
        // Track the latest reported pid (CLI agents only — used by Auto mode
        // liveness checks). Keep the last known pid if this event lacks one.
        if env.pid > 0 { s.pid = pid_t(env.pid) }

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
        NotificationCenter.default.post(name: .doomcoderNewEvent, object: nil)

        // Notification dispatch — uses user-configurable phase preferences
        // Suppress sessionEnd notifications when the agent PID is dead — this
        // means the user already quit (Cmd+Q) before the final Stop/sessionEnd
        // hook arrived. Timeline entry is still recorded above.
        //
        // IDE agents (Cursor, VS Code Copilot, Windsurf) are exempt from this
        // check because they invoke dc-hook via a short-lived shell subprocess.
        // dc-hook reports getppid() (the shell), which exits immediately after
        // dc-hook starts — so PIDLiveness always returns false for IDE-spawned
        // hooks, which would incorrectly suppress every session-end notification.
        // CLI agents (Claude, Copilot CLI, Codex) spawn dc-hook directly, so
        // getppid() is the CLI process itself, which is alive until Cmd+Q.
        let isQuitInitiatedEnd = normalized.phase == .sessionEnd
            && !normalized.agent.isIDEAgent
            && !PIDLiveness.isAlive(pid_t(env.pid))
        let shouldNotify = AgentNotificationStore.prefs(for: normalized.agent).shouldNotify(normalized)
            && !isQuitInitiatedEnd
        logger.info("ingest agent=\(normalized.agent.rawValue, privacy: .public) event=\(normalized.rawEvent, privacy: .public) phase=\(normalized.phase.rawValue, privacy: .public) notify=\(shouldNotify) quitInitiated=\(isQuitInitiatedEnd)")

        // Monotonic sequence for arbiter "later-than" correlation.
        ingestSeq += 1
        let seq = ingestSeq

        // Let the arbiter cancel any deferred approval alert that turns out to
        // have been auto-approved (a tool ran / the session ended after the
        // request). No-op when nothing is pending for this session.
        ApprovalArbiter.shared.noteEvidence(sessionKey: sessionKey, seq: seq, phase: normalized.phase)

        if shouldNotify {
            let dispatchEvent = NotificationDispatcher.Event(
                sessionKey: sessionKey, agent: normalized.agent,
                event: normalized.rawEvent, phase: normalized.phase
            )
            // Pre-decision agents fire permission hooks BEFORE their own
            // auto-approve decision runs, so defer the alert and let the
            // arbiter cancel it if the action turns out to run on its own.
            // Reliable agents (and all non-permission events) dispatch instantly.
            if normalized.phase == .permissionNeeded,
               normalized.agent.permissionHookReliability == .preDecision {
                ApprovalArbiter.shared.scheduleDeferred(
                    sessionKey: sessionKey, agent: normalized.agent, seq: seq
                ) {
                    NotificationDispatcher.shared.dispatch(dispatchEvent)
                }
            } else {
                NotificationDispatcher.shared.dispatch(dispatchEvent)
            }
        }

        // Register PID watcher for instant crash/exit detection (live sessions only).
        if s.isLive && env.pid > 0 {
            PIDWatcher.shared.watch(pid: pid_t(env.pid), sessionKey: sessionKey)
        }

        // Evict terminal sessions after configured delay
        if !s.isLive {
            // Cancel PID watcher — session ended cleanly, no need to watch for crash.
            if env.pid > 0 { PIDWatcher.shared.cancel(pid: pid_t(env.pid)) }
            // Schedule the soft demotion back to .open after autoRevertSeconds.
            scheduleTerminalRevert(sessionKey: sessionKey)
            // Schedule hard eviction after evictionDelay (long-term cleanup).
            let delay = evictionDelay
            Task { [sessionKey] in
                try? await Task.sleep(for: .seconds(delay))
                await MainActor.run {
                    if let cur = self.sessions[sessionKey],
                       Date().timeIntervalSince(cur.updatedAt) > delay {
                        self.sessions.removeValue(forKey: sessionKey)
                        self.revertTokens.removeValue(forKey: sessionKey)
                    }
                }
            }
        }
    }

}

// UI state enum — derived from SessionAggregate counters/flags.
enum AgentSessionState: String, Sendable {
    case notRunning    = "not_running"    // agent app / CLI process not detected
    case open                             // IDE open, no active session
    case running
    case waitingInput     = "waiting_input"
    case waitingApproval  = "waiting_approval"
    case completed
    case failed

    var humanReadable: String {
        switch self {
        case .notRunning:       return "closed"
        case .open:             return "idle"
        case .running:          return "running"
        case .waitingInput:     return "waiting for input"
        case .waitingApproval:  return "waiting for approval"
        case .completed:        return "completed"
        case .failed:           return "failed"
        }
    }
}
