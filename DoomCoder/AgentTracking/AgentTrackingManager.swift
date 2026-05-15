import Foundation
import Observation
import OSLog
import SwiftUI

// Central event hub. Routes raw HookEnvelopes to per-agent pipeline actors
// for normalization and SQLite persistence (off the main actor), then applies
// results here on @MainActor for UI state and notification dispatch.
//
// Each TrackedAgent gets its own PerAgentPipeline actor, so a slow hook
// burst from one agent never stalls another agent's processing.
@Observable
@MainActor
final class AgentTrackingManager {
    static let shared = AgentTrackingManager()

    private let logger = Logger(subsystem: "com.doomcoder", category: "agents")

    // One background actor per agent — normalization + SQLite run independently.
    private let pipelines: [TrackedAgent: PerAgentPipeline] = {
        Dictionary(uniqueKeysWithValues: TrackedAgent.allCases.map { ($0, PerAgentPipeline(agent: $0)) })
    }()

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
        var isActiveWindow: Bool = false

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
    private(set) var eventSequence: Int = 0
    var liveSessions: [Session] { sessions.values.filter(\.isLive).sorted { $0.updatedAt > $1.updatedAt } }

    // MARK: - Listener management

    /// Restarts the Unix-socket listener, resubscribing the ingest callback.
    /// Call when the Doctor determines the listener is not running.
    func restartListener() {
        HookSocketListener.shared.stop()
        // Small delay so the raw fd has time to close before rebinding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            HookSocketListener.shared.start { env in
                Task { @MainActor in AgentTrackingManager.shared.ingest(env) }
            }
        }
    }

    // MARK: - Active-window observation

    /// Start observing ActiveAppMonitor so session.isActiveWindow stays current.
    func startActiveWindowObservation() {
        observeActiveWindow()
    }

    private func observeActiveWindow() {
        withObservationTracking {
            _ = ActiveAppMonitor.shared.frontmost
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateActiveWindows()
                self?.observeActiveWindow()
            }
        }
    }

    private func updateActiveWindows() {
        let entry = ActiveAppMonitor.shared.frontmost
        for key in sessions.keys {
            guard let session = sessions[key] else { continue }
            var active = false
            if let e = entry, e.agent == session.agent {
                if e.cwd.isEmpty {
                    active = true
                } else {
                    let sCwd = session.cwd
                    active = sCwd.hasPrefix(e.cwd) || e.cwd.hasPrefix(sCwd)
                }
            }
            if sessions[key]?.isActiveWindow != active {
                sessions[key]?.isActiveWindow = active
            }
        }
    }

    // MARK: - Active-state tracking (60-second recency window)

    /// Timestamp of the last successfully ingested hook event per agent.
    /// Used to derive AgentRunState.active without re-probing NSWorkspace.
    private(set) var lastHookAt: [String: Date] = [:]

    /// Returns true if the agent sent a hook event in the last 60 seconds.
    func isActive(_ agent: TrackedAgent) -> Bool {
        guard let last = lastHookAt[agent.rawValue] else { return false }
        return Date().timeIntervalSince(last) < 60
    }

    // MARK: - 5-state agent tracking

    /// Published 5-state per-agent status, driven by AgentStateEngine.
    private(set) var agentStates: [TrackedAgent: AgentState] = {
        Dictionary(uniqueKeysWithValues: TrackedAgent.allCases.map { ($0, .installed) })
    }()

    /// Per-agent state machines.
    private var engines: [TrackedAgent: AgentStateEngine] = [:]

    private init() {
        for a in TrackedAgent.allCases {
            engines[a] = AgentStateEngine(agent: a) { [weak self] agent, state in
                Task { @MainActor [weak self] in self?.agentStates[agent] = state }
            }
        }
    }

    /// Current 5-state for an agent.
    func agentState(for agent: TrackedAgent) -> AgentState {
        agentStates[agent] ?? .installed
    }

    // MARK: - NSWorkspace monitoring (app-level lifecycle)

    private var workspaceLaunchObserver:    (any NSObjectProtocol)?
    private var workspaceTerminateObserver: (any NSObjectProtocol)?

    func startNSWorkspaceMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter

        workspaceLaunchObserver = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let agent = ActiveAppMonitor.bundleToAgent[app.bundleIdentifier ?? ""] else { return }
            let pid = app.processIdentifier
            Task { [weak self] in await self?.engines[agent]?.applyProcessAlive(pid: pid) }
        }

        workspaceTerminateObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let agent = ActiveAppMonitor.bundleToAgent[app.bundleIdentifier ?? ""] else { return }
            Task { [weak self] in await self?.engines[agent]?.applyProcessNotFound() }
        }
    }

    // MARK: - Periodic process polling (for CLI agents)

    private var processPollTask: Task<Void, Never>?

    func startProcessPolling() {
        guard processPollTask == nil else { return }
        processPollTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                await self?.pollProcessStates()
            }
        }
        // Run an initial poll immediately.
        Task.detached(priority: .utility) { [weak self] in await self?.pollProcessStates() }
    }

    private func pollProcessStates() async {
        let detections = await Task.detached(priority: .utility) { AgentDetector.detectAll() }.value
        await MainActor.run { [weak self] in
            guard let self else { return }
            for detection in detections {
                let agent = detection.agent
                let runState = detection.runState
                Task { await self.engines[agent]?.applyDetectionResult(runState) }
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

        // Always capture raw envelope for Live Events before routing.
        LiveEventsStore.shared.append(env)

        guard let agent = TrackedAgent(rawValue: env.agent),
              let pipeline = pipelines[agent] else {
            logger.notice("drop: unknown agent '\(env.agent, privacy: .public)'")
            return
        }

        // Stamp last-hook time immediately (on main actor) for AgentRunState.active.
        lastHookAt[agent.rawValue] = Date()

        // Off-load normalization + SQLite write to the per-agent pipeline actor.
        // The pipeline runs on its own isolated queue, so multiple agents process
        // concurrently without serialising on the main actor.
        Task { [weak self, env, pipeline] in
            let normalized = await pipeline.process(env)
            // Apply UI state and notification dispatch back on the main actor.
            await MainActor.run { [weak self] in
                self?.apply(normalized: normalized, envelope: env)
            }
        }
    }

    // MARK: - Main-actor session state + notification dispatch

    private func apply(normalized: NormalizedHookEvent, envelope: HookEnvelope) {
        let sessionKey = "\(normalized.agent.rawValue)::\(normalized.sessionId)"

        let payloadStr: String? = envelope.payloadRaw.flatMap { String(data: $0, encoding: .utf8) }
        let timelineEvent = TimelineEvent(
            event: normalized.rawEvent,
            phase: normalized.phase,
            tool: normalized.toolName,
            path: normalized.filePath ?? normalized.cwd,
            timestamp: normalized.timestamp,
            summary: normalized.summary,
            rawPayload: payloadStr
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

        // Assign without withAnimation — animation applied at the view layer
        // via .animation(value:) to avoid NSHostingView constraint loops.
        sessions[sessionKey] = s
        eventSequence &+= 1

        // Signal the 5-state engine with the now-normalized phase.
        let envPID = pid_t(envelope.pid)
        Task { [weak self] in await self?.engines[normalized.agent]?.applyHookSignal(phase: normalized.phase, pid: envPID) }

        // Terminal hooks (sessionEnd / stop) fire as part of the agent's
        // shutdown sequence — the process exits immediately after sending the
        // hook, so a PID-liveness check would always suppress them. Rely on
        // the session-eviction logic for stale/phantom cleanup instead.
        let shouldNotify = NotificationPolicy.isNotifiable(agent: normalized.agent, rawEvent: normalized.rawEvent, phase: normalized.phase)
        logger.info("apply agent=\(normalized.agent.rawValue, privacy: .public) event=\(normalized.rawEvent, privacy: .public) phase=\(normalized.phase.rawValue, privacy: .public) notify=\(shouldNotify)")
        if shouldNotify {
            NotificationDispatcher.shared.dispatch(.init(
                sessionKey: sessionKey, agent: normalized.agent,
                event: normalized.rawEvent, phase: normalized.phase
            ))
        }

        // Evict terminal sessions after configured delay.
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
