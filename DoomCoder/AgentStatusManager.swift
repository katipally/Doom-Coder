import Foundation
import Observation

// MARK: - AgentStatusManager
//
// Central state machine that consumes events from SocketServer (hooks + MCP) and
// keeps a list of live sessions. Drives every downstream effect:
//   • SleepManager — any active (non-done) session extends the wake assertion
//   • NotificationManager — attention events (wait/error/done) produce banners
//   • IPhoneRelay (Phase C) — same attention events produce iPhone notifications
//   • LiveActivityManager (Phase D) — per-session activity updates
//
// All mutations happen on @MainActor, so the UI observes this with zero bridging.

@Observable
@MainActor
final class AgentStatusManager {

    // MARK: - Observable state

    private(set) var sessions: [AgentSession] = []
    private(set) var isAnyAgentActive: Bool = false
    private(set) var lastEventAt: Date?

    // MARK: - Config

    // Sessions with no events for this long are force-finalised to `.done`.
    let staleTimeout: TimeInterval = 10 * 60

    // Duplicate attention events within this window (per session, per status) are
    // dropped. Protects against hooks + MCP both firing for the same event.
    let dedupWindow: TimeInterval = 10.0

    // MARK: - Downstream sinks (wired up in DoomCoderApp)

    // Called for every meaningful state change; receivers should be idempotent.
    // Use `session.state` / `event.status` to decide what to do.
    var onSessionUpdated: ((AgentSession, AgentEvent) -> Void)?

    // Called when `isAnyAgentActive` flips. SleepManager listens here.
    var onActivityChanged: ((Bool) -> Void)?

    // MARK: - Private state

    @ObservationIgnored private var sessionsById: [String: Int] = [:]   // id → index into sessions
    @ObservationIgnored private var lastDelivered: [String: (status: AgentEvent.Status, at: Date)] = [:]
    @ObservationIgnored nonisolated(unsafe) private var _reaperTimer: Timer?

    // MARK: - Init / Deinit

    init() {
        startReaperTimer()
    }

    deinit {
        _reaperTimer?.invalidate()
    }

    // MARK: - Ingest

    func ingest(_ event: AgentEvent) {
        lastEventAt = Date.now

        let key = event.sessionKey
        let now = Date.now

        if let idx = sessionsById[key] {
            var session = sessions[idx]
            session.lastEventAt = now
            if let c = event.cwd, !c.isEmpty { session.cwd = c }
            if let t = event.tool, !t.isEmpty {
                session.currentTool = t
                session.toolCount += 1
            }
            if let m = event.message, !m.isEmpty { session.lastMessage = m }
            session.source = event.src
            session.state = stateFor(event.status)
            sessions[idx] = session
            deliver(session, event: event, now: now)
        } else {
            let new = AgentSession(
                id: key,
                agent: event.agent,
                startedAt: now,
                state: stateFor(event.status),
                lastEventAt: now,
                cwd: event.cwd,
                currentTool: event.tool,
                toolCount: event.tool != nil ? 1 : 0,
                lastMessage: event.message,
                source: event.src
            )
            sessions.append(new)
            sessionsById[key] = sessions.count - 1
            deliver(new, event: event, now: now)
        }

        recomputeActivity()

        // If session just hit a terminal state, prune after a brief delay so the
        // Status UI can show "Done" for a moment.
        if event.status == .done { schedulePrune(sessionId: key, delay: 5) }
    }

    // MARK: - Helpers

    private func stateFor(_ status: AgentEvent.Status) -> AgentSession.State {
        switch status {
        case .start, .info: return .active
        case .wait:         return .waiting
        case .error:        return .errored
        case .done:         return .done
        }
    }

    private func deliver(_ session: AgentSession, event: AgentEvent, now: Date) {
        // Dedup window guard for attention events. Non-attention events always pass.
        if event.status.isAttention {
            if let last = lastDelivered[session.id],
               last.status == event.status,
               now.timeIntervalSince(last.at) < dedupWindow {
                return
            }
            lastDelivered[session.id] = (event.status, now)
        }
        onSessionUpdated?(session, event)
    }

    private func recomputeActivity() {
        let active = sessions.contains { $0.state != .done }
        if active != isAnyAgentActive {
            isAnyAgentActive = active
            onActivityChanged?(active)
        }
    }

    // MARK: - Pruning & reaping

    private func schedulePrune(sessionId: String, delay: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.prune(sessionId: sessionId)
        }
    }

    private func prune(sessionId: String) {
        guard let idx = sessionsById[sessionId] else { return }
        sessions.remove(at: idx)
        sessionsById.removeValue(forKey: sessionId)
        // Rebuild index since removal shifts later entries.
        sessionsById = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($0.element.id, $0.offset) })
        recomputeActivity()
    }

    private func startReaperTimer() {
        // Check every 60s for sessions that haven't received events in `staleTimeout`.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapStaleSessions() }
        }
        RunLoop.main.add(t, forMode: .common)
        _reaperTimer = t
    }

    private func reapStaleSessions() {
        let now = Date.now
        let stale = sessions.filter { $0.state != .done && now.timeIntervalSince($0.lastEventAt) > staleTimeout }
        for var s in stale {
            s.state = .done
            s.lastMessage = (s.lastMessage ?? "") + " (timed out)"
            if let idx = sessionsById[s.id] { sessions[idx] = s }
            let synthetic = AgentEvent(
                src: s.source,
                agent: s.agent,
                status: .done,
                sessionId: s.id,
                cwd: s.cwd,
                message: "Timed out after \(Int(staleTimeout / 60)) min"
            )
            onSessionUpdated?(s, synthetic)
            schedulePrune(sessionId: s.id, delay: 1)
        }
    }

    // MARK: - Test/Manual helpers

    // Injects a fake event as if it came from a hook. Used by Settings "Send Test".
    func injectTest(agent: String, status: AgentEvent.Status, message: String? = nil) {
        ingest(AgentEvent(
            src: .manual,
            agent: agent,
            status: status,
            sessionId: "test-\(UUID().uuidString.prefix(8))",
            message: message ?? "Test from DoomCoder"
        ))
    }

    // Wipes all state (for tests and for the "Reset" button).
    func reset() {
        sessions.removeAll()
        sessionsById.removeAll()
        lastDelivered.removeAll()
        recomputeActivity()
    }
}
