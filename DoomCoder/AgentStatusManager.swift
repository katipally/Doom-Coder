import Foundation
import Observation

// MARK: - WatchTarget
//
// v1.5: replaces the old `watchedSessionKey: String` model with a small
// explicit enum so the menubar's Track submenu can represent three
// mutually-exclusive states cleanly:
//   • .none           — silent; no notifications fire at all
//   • .all            — every *configured* agent fires (default)
//   • .agentType(id)  — only sessions whose agent id matches fire
//
// Per-instance (`.session(id)`) tracking was removed in v1.5 — instances
// were unstable between launches and users found them confusing.

enum WatchTarget: Codable, Hashable, Sendable {
    case none
    case all
    case agentType(String)
}

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
    // Raised from 10 → 30 min in v1.3: real Claude sessions routinely idle
    // much longer between prompts, and the previous timeout was prematurely
    // marking live work as stale.
    let staleTimeout: TimeInterval = 30 * 60

    // Duplicate attention events within this window (per session / status /
    // tool triple) are dropped. Keying by tool too (v1.3) lets back-to-back
    // permission prompts for different tools through without collapsing.
    let dedupWindow: TimeInterval = 10.0

    // MARK: - Downstream sinks (wired up in DoomCoderApp)

    // Called for every meaningful state change; receivers should be idempotent.
    // Use `session.state` / `event.status` to decide what to do.
    var onSessionUpdated: ((AgentSession, AgentEvent) -> Void)?

    // Called when `isAnyAgentActive` flips. SleepManager listens here.
    var onActivityChanged: ((Bool) -> Void)?

    // MARK: - Private state

    @ObservationIgnored private var sessionsById: [String: Int] = [:]   // id → index into sessions
    // Dedup keyed by (sessionId, status.rawValue, tool ?? "") so two distinct
    // tool permission prompts in quick succession don't collapse.
    @ObservationIgnored private var lastDelivered: [String: (at: Date, status: AgentEvent.Status, tool: String)] = [:]
    // Most recent MCP-hello timestamps keyed by agent id. Populated by
    // `ingestHello(agent:installId:)` and surfaced to the UI as "Live".
    // Persisted across launches under `dc.mcpHelloAt` so an MCP agent stays
    // "Configured" even after a restart (the user did the work once).
    @ObservationIgnored private(set) var mcpHelloAt: [String: Date] = [:]
    // Set to `true` per agent id when HookRoundTripTest reports success.
    // Persisted across launches under `dc.didRoundTrip` so a hook agent
    // stays "Configured" between restarts.
    @ObservationIgnored private(set) var didRoundTrip: [String: Bool] = [:]
    @ObservationIgnored nonisolated(unsafe) private var _reaperTimer: Timer?

    // Round-trip test continuations keyed by nonce. A nonce is set by
    // HookRoundTripTest via the DC_TEST_NONCE env var; when hook.sh echoes it
    // back in an event, we resume the continuation and consume the event
    // without creating a session row.
    @ObservationIgnored private var roundTripWaiters: [String: CheckedContinuation<AgentEvent, Never>] = [:]

    // MARK: - Init / Deinit

    init() {
        // v1.5: restore the new WatchTarget model. We also honour the legacy
        // `dc.watchedSessionKey` key one last time — empty → .all, anything
        // else → .all too (the old session ids were unstable across launches
        // so carrying them forward is worse than starting clean).
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: "dc.watchTarget"),
           let decoded = try? JSONDecoder().decode(WatchTarget.self, from: data) {
            self.watchTarget = decoded
        } else if let legacy = ud.string(forKey: "dc.watchedSessionKey") {
            self.watchTarget = legacy.isEmpty ? .all : .all
            ud.removeObject(forKey: "dc.watchedSessionKey")
        } else {
            self.watchTarget = .all
        }

        // Restore the per-agent "configured" flags. Any missing entry means
        // the agent has never been verified → not configured yet.
        if let raw = ud.dictionary(forKey: "dc.didRoundTrip") as? [String: Bool] {
            self.didRoundTrip = raw
        }
        if let raw = ud.dictionary(forKey: "dc.mcpHelloAt") as? [String: Double] {
            self.mcpHelloAt = raw.mapValues { Date(timeIntervalSince1970: $0) }
        }

        startReaperTimer()
    }

    deinit {
        _reaperTimer?.invalidate()
    }

    // MARK: - Ingest

    func ingest(_ event: AgentEvent) {
        lastEventAt = Date.now

        // Round-trip test observers: if any test is waiting on a nonce, fire it.
        if let n = event.nonce, !n.isEmpty, let cont = roundTripWaiters.removeValue(forKey: n) {
            cont.resume(returning: event)
            // Round-trip test events are synthetic — do not materialize as a
            // session. Otherwise the sidebar flashes a phantom "Test" row.
            return
        }

        // MCP-hello is a side-channel handshake, not a real session event.
        // We intercept it before session tracking so a phantom "mcp-hello"
        // row never appears in the sidebar. The `tool` field carries the
        // install-id the MCP server was invoked with.
        if event.src == .mcp, (event.message ?? "").hasPrefix("mcp-hello") {
            ingestHello(agent: event.agent, installId: event.tool)
            MCPInstaller.recordHello(agent: event.agent, installId: event.tool ?? "")
            // mcp.py v4 embeds the client's self-reported name in either the
            // message suffix ("mcp-hello:Cursor") or the cwd field. Persist it
            // so Install Anywhere verify can show which IDE loaded the config.
            let msg = event.message ?? ""
            var clientName = ""
            if let colon = msg.firstIndex(of: ":") {
                clientName = String(msg[msg.index(after: colon)...])
            }
            if clientName.isEmpty, let c = event.cwd { clientName = c }
            if !clientName.isEmpty {
                MCPInstaller.recordClientName(agent: event.agent, clientName: clientName)
            }
            return
        }

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

    // MARK: - Public config

    // v1.5: tri-state target for which agents fire notifications.
    //   • .none            — silent
    //   • .all             — every configured agent (default)
    //   • .agentType(id)   — only sessions from this agent id
    // `isWatched(_:)` below applies the gate. The menubar's Track submenu
    // and the Configure window's per-agent "Track" button both write here.
    var watchTarget: WatchTarget = .all {
        didSet {
            if let data = try? JSONEncoder().encode(watchTarget) {
                UserDefaults.standard.set(data, forKey: "dc.watchTarget")
            }
        }
    }

    // MARK: - Configured-agent helpers

    // An agent counts as "configured" once the user has proven their wiring
    // end-to-end: a hook agent needs a successful round-trip, an MCP agent
    // needs a hello handshake. Both facts are persisted.
    func isAgentConfigured(_ id: String) -> Bool {
        if let hook = HookInstaller.Agent(rawValue: id) {
            // Hook-tier: require an installed hook AND a verified round-trip.
            return HookInstaller.status(for: hook).isInstalled
                && (didRoundTrip[id] ?? false)
        }
        if let mcp = MCPInstaller.Agent.allCases.first(where: { $0.catalogId == id }) {
            let status = MCPInstaller.status(for: mcp)
            let hasConfig = (status == .live || status == .configWritten || status == .modified)
            return hasConfig && (mcpHelloAt[id] != nil)
        }
        return false
    }

    // The full ordered list of agents the user has configured. The menubar
    // Track submenu renders exactly this list; the Configure window's Track
    // buttons use the same predicate for enablement.
    func configuredAgents() -> [AgentCatalog.Info] {
        AgentCatalog.all.filter { isAgentConfigured($0.id) }
    }

    // Called by HookRoundTripTest on success. Persists the flag so a future
    // launch still considers the agent configured without re-running the test.
    func markRoundTripSuccess(agentId: String) {
        didRoundTrip[agentId] = true
        UserDefaults.standard.set(didRoundTrip, forKey: "dc.didRoundTrip")
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

    // Returns true if the session should feed the downstream notification
    // pipeline. The gate honours the user's WatchTarget:
    //   • .none            — never fire
    //   • .all             — fire only for agents that are already configured
    //   • .agentType(id)   — fire only if the session's agent id matches
    func isWatched(_ session: AgentSession) -> Bool {
        switch watchTarget {
        case .none:
            return false
        case .all:
            return isAgentConfigured(session.agent)
        case .agentType(let id):
            return session.agent == id
        }
    }

    private func deliver(_ session: AgentSession, event: AgentEvent, now: Date) {
        // Strict watch filter: drop everything not matching the user's
        // selection from the menubar. The session row still updates (so
        // the sidebar is honest about what's happening), but no banner,
        // iPhone push, or sleep-extend fires for unwatched sessions.
        guard isWatched(session) else { return }

        // Dedup window guard for attention events. Non-attention events always pass.
        if event.status.isAttention {
            let tool = event.tool ?? ""
            let key = "\(session.id)|\(event.status.rawValue)|\(tool)"
            if let last = lastDelivered[key],
               last.status == event.status,
               last.tool == tool,
               now.timeIntervalSince(last.at) < dedupWindow {
                return
            }
            lastDelivered[key] = (now, event.status, tool)
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

    // MARK: - MCP handshake
    //
    // The MCP server script calls `dc` with a synthetic "mcp-hello" message on
    // its `initialize` RPC, so we know the agent loaded the config. We track
    // the latest hello per agent id and expose it to the UI as a "Live" pill.

    func ingestHello(agent: String, installId: String?) {
        mcpHelloAt[agent] = Date.now
        // Persist the whole dict so the agent keeps counting as "configured"
        // after an app restart (v1.5).
        let snapshot: [String: Double] = mcpHelloAt.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(snapshot, forKey: "dc.mcpHelloAt")
        if let installId, !installId.isEmpty {
            // Stash the hello timestamp in UserDefaults keyed by (agent, install-id)
            // so the UI can confirm "this specific install is live" across launches.
            UserDefaults.standard.set(Date.now.timeIntervalSince1970,
                                      forKey: "dc.mcp.hello.\(agent).\(installId)")
        }
    }

    /// Returns the timestamp of the most recent MCP hello for the given
    /// agent, or nil if none has been seen. Used by MCPInstaller.liveStatus.
    func lastHello(for agent: String) -> Date? {
        mcpHelloAt[agent]
    }

    // MARK: - Test/Manual helpers

    // Registers a waiter for a round-trip nonce. The returned async function
    // suspends until either the nonce arrives on the socket or the timeout
    // elapses. Consumer: HookRoundTripTest.
    func awaitRoundTrip(nonce: String, timeout: TimeInterval) async -> AgentEvent? {
        // Schedule a timeout that will resume the continuation with a
        // sentinel event if no real event arrives first.
        let event: AgentEvent = await withCheckedContinuation { (cont: CheckedContinuation<AgentEvent, Never>) in
            roundTripWaiters[nonce] = cont
            let nonceCopy = nonce
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if let pending = self?.roundTripWaiters.removeValue(forKey: nonceCopy) {
                    pending.resume(returning: AgentEvent(
                        src: .manual, agent: "__dc-timeout__", status: .info
                    ))
                }
            }
        }
        if event.agent == "__dc-timeout__" { return nil }
        return event
    }

    // Injects a fake event as if it came from a hook. Used by Settings "Send Test".
    // In v1.3 this fires a 3-stage sequence (start → wait → done) so the test
    // session doesn't zombie in the sidebar.
    func injectTest(agent: String, status: AgentEvent.Status, message: String? = nil) {
        let sid = "test-\(UUID().uuidString.prefix(8))"
        let label = message ?? "Test from DoomCoder"

        // Stage 1: start immediately.
        ingest(AgentEvent(
            src: .manual, agent: agent, status: .start,
            sessionId: String(sid),
            message: label
        ))

        // Stage 2: transition to the requested status after 1.5s (usually .wait).
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            self?.ingest(AgentEvent(
                src: .manual, agent: agent, status: status,
                sessionId: String(sid),
                message: label
            ))
            // Stage 3: close it out 3s later so the row doesn't linger forever.
            try? await Task.sleep(for: .milliseconds(3000))
            self?.ingest(AgentEvent(
                src: .manual, agent: agent, status: .done,
                sessionId: String(sid),
                message: "Test complete"
            ))
        }
    }

    // Wipes all state (for tests and for the "Reset" button).
    // NOTE: persisted "configured" flags (didRoundTrip, mcpHelloAt) are
    // intentionally preserved — the user did the setup work, we shouldn't
    // invalidate that just because the session list got cleared.
    func reset() {
        sessions.removeAll()
        sessionsById.removeAll()
        lastDelivered.removeAll()
        recomputeActivity()
    }
}
