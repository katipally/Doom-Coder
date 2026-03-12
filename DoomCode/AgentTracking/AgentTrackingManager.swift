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

    /// Per-session token for the 120-second `awaitingPermission` safety-net.
    /// Bumped (by removal) when the permission is cleared by a follow-up event.
    private var permissionTimeoutTokens: [String: Int] = [:]

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
        /// Timestamp carried by the hook event itself. Cross-process and
        /// clock-skewed — fine for display/history ordering, but NOT a reliable
        /// "is the agent alive right now" signal.
        var updatedAt: Date
        /// Local wall-clock time when this Mac actually *received* the most
        /// recent hook for the session. This is the authoritative "hooks are
        /// firing" signal for Auto-mode sleep decisions: it is immune to remote
        /// clock skew and can never be in the future. Defaults to distantPast
        /// until the first hook lands.
        var lastHookReceivedAt: Date = .distantPast
        /// Last reported OS process id for this session. Meaningful only for
        /// CLI agents (they spawn dc-hook directly); IDE agents report a
        /// throwaway shell pid, so liveness must not be inferred from it.
        var pid: pid_t = 0

        // Counters
        var toolCallCount: Int = 0
        var activeToolCount: Int = 0
        var errorCount: Int = 0
        var subagentCount: Int = 0
        var permissionCount: Int = 0

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
                permissionCount += 1
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

    /// Local wall-clock timestamp of the most recent hook per agent — the
    /// auto-sleep truth source. Immune to remote clock skew.
    private(set) var lastHookByAgent: [TrackedAgent: Date] = [:]
    /// Most recent hook from ANY agent — single signal for the global 10-min timer.
    private(set) var lastAnyHookAt: Date = .distantPast

    /// Unique agent types with a hook received in the last 10 minutes.
    var hookFreshAgents: [TrackedAgent] {
        let cutoff = Date().addingTimeInterval(-600)
        return lastHookByAgent.compactMap { agent, t in t > cutoff ? agent : nil }
    }

    /// Single source of truth for an agent's effective display state, used by
    /// the panel UI (TrackAgentsView/TrackAccordion) AND the Mac→iOS publisher
    /// so both always agree.
    ///
    /// Rules:
    ///   • A live tracked session → its `displayState` (hook-driven truth).
    ///   • No session, but an IDE app is running → `.open` (present, not working).
    ///   • No session for a CLI agent → `.notRunning`. CLI presence is detected
    ///     by matching a process named "claude"/"codex"/"copilot", which cannot
    ///     distinguish an idle REPL or a name-collision from real work — so we
    ///     must NOT report `.running` without an active hook session. This is
    ///     what eliminates the "Claude Code · running" false positive.
    func effectiveState(for agent: TrackedAgent) -> AgentSessionState {
        if let live = liveSessions.first(where: { $0.agent == agent }) {
            return live.displayState
        }
        if agent.isIDEAgent, processMonitor.isAppRunning[agent] == true {
            return .open
        }
        return .notRunning
    }

    /// Monotonic counter stamped on every ingested event. Used by
    /// `ApprovalArbiter` for "arrived after the permission request" reasoning
    /// (hook timestamps are cross-process and skewed, so they can't be trusted
    /// for ordering).
    private var ingestSeq: Int = 0

    private init() {
        // Periodic eviction sweep + liveness reconciliation. Scheduled in
        // `.common` modes so stale IDE sessions revert and dead CLI sessions
        // finalize even while the menu panel is open. 20s bounds how long a
        // PIDWatcher-missed exit can show a ghost "running" badge.
        let sweep = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sweepEvictedSessions() }
        }
        RunLoop.main.add(sweep, forMode: .common)
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
        // Process is gone — drop any deferred approval alert and pending
        // permission-timeout token so a killed approval-waiting session can't
        // later fire stale "stuck" logic.
        permissionTimeoutTokens.removeValue(forKey: sessionKey)
        ApprovalArbiter.shared.clear(sessionKey: sessionKey)
        NotificationCenter.default.post(name: .doomcoderNewEvent, object: nil)
        scheduleTerminalRevert(sessionKey: sessionKey)
    }

    private func sweepEvictedSessions() {
        var changed = false
        let now = Date()
        // Matches the 10-min hook window used by SleepManager — IDE hooks older
        // than this are treated as idle.
        let ideIdleWindow: TimeInterval = 600
        // Grace before finalizing a live CLI session that never reported a pid:
        // gives a freshly-started session time to emit its first pid-bearing hook.
        let noPidGrace: TimeInterval = 90
        for key in Array(sessions.keys) {
            guard let s = sessions[key] else { continue }

            // IDE agent stuck in a live state with stale hooks: soft-revert it so
            // the UI transitions to idle instead of showing a ghost "running" badge.
            if s.isLive, s.agent.isIDEAgent,
               now.timeIntervalSince(s.updatedAt) > ideIdleWindow {
                scheduleTerminalRevert(sessionKey: key)
                changed = true
                continue
            }

            // CLI liveness safety-net (authoritative for "is it running?").
            // PIDWatcher should already finalize on exit, but it can miss when a
            // hook arrived without a pid, or the process was force-killed before
            // the watcher registered. Reconcile here so a dead agent never lingers
            // as a false-positive "running" badge for up to evictionDelay.
            if s.isLive, !s.agent.isIDEAgent {
                if s.pid > 0, !PIDLiveness.isAlive(s.pid) {
                    finalizeOnPIDExit(sessionKey: key)
                    changed = true
                    continue
                }
                // No pid ever captured: fall back to the process monitor. Only
                // finalize once past the grace window and the monitor confirms no
                // matching CLI process is running (avoids cutting a real task).
                if s.pid == 0,
                   now.timeIntervalSince(s.lastHookReceivedAt) > noPidGrace,
                   processMonitor.isAppRunning[s.agent] != true {
                    finalizeOnPIDExit(sessionKey: key)
                    changed = true
                    continue
                }
                // Process still alive: never evict — a long-running CLI agent can
                // run quietly (no hook events) for well over evictionDelay.
                if s.pid > 0, PIDLiveness.isAlive(s.pid) { continue }
            }

            guard now.timeIntervalSince(s.updatedAt) > evictionDelay else { continue }
            sessions.removeValue(forKey: key)
            revertTokens.removeValue(forKey: key)
            permissionTimeoutTokens.removeValue(forKey: key)
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

        // Snapshot the session now for history persistence (before reset).
        let snapshot = sessions[sessionKey]

        Task { [sessionKey, nextToken, snapshot] in
            try? await Task.sleep(for: .seconds(delay))
            await MainActor.run {
                guard self.revertTokens[sessionKey] == nextToken else { return }
                guard var s = self.sessions[sessionKey] else { return }
                guard s.hasEnded || s.hasFailed else { return }

                // Persist session summary before resetting flags.
                if let snap = snapshot {
                    let outcome = snap.hasFailed ? "failed" : (snap.hasEnded ? "completed" : "reverted")
                    EventStore.shared.insertSessionHistory(
                        sessionKey: sessionKey,
                        agent: snap.agent.rawValue,
                        startedAt: snap.startedAt,
                        endedAt: snap.updatedAt,
                        outcome: outcome,
                        toolCount: snap.toolCallCount,
                        permissionCount: snap.permissionCount,
                        subagentCount: snap.subagentCount
                    )
                }

                s.hasEnded = false
                s.hasFailed = false
                s.lastPhase = .sessionStart
                self.sessions[sessionKey] = s
                NotificationCenter.default.post(name: .doomcoderNewEvent, object: nil)
            }
        }
    }

    /// Safety-net: if a permission request fires but no subsequent tool/prompt
    /// event arrives within 120 s, auto-clear `awaitingPermission`. This handles
    /// the case where the user approves in the agent app but the follow-up hook
    /// is dropped (network hiccup, app crash, mismatched event format).
    /// (v2.6: the prior 30-min "agent is stuck" notification was removed — it
    /// was a noisy false positive, since a long lull doesn't necessarily mean
    /// the user is away. Auto mode's keyboard/mouse signal handles that case
    /// better, and the agent's own UI surfaces the pending approval.)
    private func schedulePermissionTimeout(sessionKey: String) {
        let nextToken = (permissionTimeoutTokens[sessionKey] ?? 0) + 1
        permissionTimeoutTokens[sessionKey] = nextToken

        Task { [sessionKey, nextToken] in
            try? await Task.sleep(for: .seconds(120))
            await MainActor.run {
                guard self.permissionTimeoutTokens[sessionKey] == nextToken else { return }
                guard var s = self.sessions[sessionKey], s.awaitingPermission else { return }
                s.awaitingPermission = false
                self.sessions[sessionKey] = s
                self.permissionTimeoutTokens.removeValue(forKey: sessionKey)
                NotificationCenter.default.post(name: .doomcoderNewEvent, object: nil)
                self.logger.info("permission timeout: auto-cleared awaitingPermission for \(sessionKey, privacy: .public)")
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
        let hadPermission = s.awaitingPermission
        s.apply(normalized)
        // Receipt-time stamp: the real "a hook just fired" signal for Auto mode.
        let hookReceivedAt = Date()
        s.lastHookReceivedAt = hookReceivedAt
        lastHookByAgent[normalized.agent] = hookReceivedAt
        lastAnyHookAt = hookReceivedAt
        // Track the latest reported pid (CLI agents only — used by Auto mode
        // liveness checks). Keep the last known pid if this event lacks one.
        if env.pid > 0 { s.pid = pid_t(env.pid) }

        // Assign without wrapping in withAnimation. Animation is applied at
        // the view layer via .animation(value:) on the sessions list, which
        // is safer than driving SwiftUI transactions from a socket-delivered
        // mutation (prior approach risked NSHostingView constraint loops when
        // hosted under MenuBarExtra(.window)).
        sessions[sessionKey] = s

        // Permission flag lifecycle: start a 120s safety-net when a permission
        // request arrives; invalidate the token as soon as work resumes.
        if !hadPermission && s.awaitingPermission {
            schedulePermissionTimeout(sessionKey: sessionKey)
        } else if hadPermission && !s.awaitingPermission {
            permissionTimeoutTokens.removeValue(forKey: sessionKey)
        }

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
