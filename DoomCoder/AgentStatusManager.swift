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
    // Per-agent timestamp of the first real `dc` tool call received over MCP
    // (anything not a hello). Presence of this proves the agent both loaded
    // the config AND read the rules snippet — the two-gate setup contract.
    // Persisted under `dc.mcpLastToolCallAt`.
    @ObservationIgnored private(set) var mcpLastToolCallAt: [String: Date] = [:]
    // Set to `true` per agent id when HookRoundTripTest reports success.
    // Persisted across launches under `dc.didRoundTrip` so a hook agent
    // stays "Configured" between restarts.
    @ObservationIgnored private(set) var didRoundTrip: [String: Bool] = [:]
    // Sticky "this agent finished setup successfully at least once" flag.
    // Persisted under `dc.configuredAgentIds`. Only cleared on explicit
    // Uninstall. Decouples the Track UI from live handshake state so a
    // previously-verified agent stays tickable across restarts / idle periods.
    @ObservationIgnored private(set) var configuredAgentIds: Set<String> = []
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
        if let raw = ud.dictionary(forKey: "dc.mcpLastToolCallAt") as? [String: Double] {
            self.mcpLastToolCallAt = raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
        if let arr = ud.array(forKey: "dc.configuredAgentIds") as? [String] {
            self.configuredAgentIds = Set(arr)
        }

        startReaperTimer()
    }

    deinit {
        _reaperTimer?.invalidate()
    }

    // MARK: - Recent events (live feed for Agent detail pane)
    //
    // Ring buffer of the last N `dc` calls, regardless of whether they passed
    // the watch gate or triggered a notification. The UI filters by agent id
    // to render a per-agent live feed so the user can see — in real time —
    // whether their agent is actually honoring the rules snippet.
    //
    // Each entry carries the gate decision (accepted / dropped-not-watched /
    // dropped-dedup / etc.) so the user can tell at a glance whether a silent
    // phone means "agent didn't call" vs "we dropped it" vs "ntfy failed".

    struct RecentEvent: Identifiable, Sendable {
        enum GateDecision: Sendable {
            case accepted
            case droppedNotWatched
            case droppedDedup
            case droppedHello        // intercepted before session pipeline
            case droppedTestNonce    // consumed by round-trip test
        }
        let id: UUID = UUID()
        let timestamp: Date
        let agent: String
        let status: AgentEvent.Status
        let source: AgentEvent.Source
        let message: String?
        let gate: GateDecision
    }

    private(set) var recentEvents: [RecentEvent] = []
    private let recentEventsMax = 50

    func clearRecentEvents() { recentEvents.removeAll() }

    func recentEvents(for agentId: String, limit: Int = 50) -> [RecentEvent] {
        recentEvents.filter { $0.agent == agentId }.prefix(limit).map { $0 }
    }

    private func recordRecent(_ event: AgentEvent, gate: RecentEvent.GateDecision) {
        let entry = RecentEvent(
            timestamp: Date.now,
            agent: event.agent,
            status: event.status,
            source: event.src,
            message: event.message,
            gate: gate
        )
        recentEvents.insert(entry, at: 0)
        if recentEvents.count > recentEventsMax {
            recentEvents = Array(recentEvents.prefix(recentEventsMax))
        }
    }

    // MARK: - Ingest

    func ingest(_ event: AgentEvent) {
        lastEventAt = Date.now

        Log.ingest.info("agent=\(event.agent, privacy: .public) status=\(event.status.rawValue, privacy: .public) src=\(event.src.rawValue, privacy: .public)")

        // Round-trip test observers: if any test is waiting on a nonce, fire it.
        if let n = event.nonce, !n.isEmpty, let cont = roundTripWaiters.removeValue(forKey: n) {
            cont.resume(returning: event)
            recordRecent(event, gate: .droppedTestNonce)
            return
        }

        // MCP-hello is a side-channel handshake, not a real session event.
        if event.src == .mcp, (event.message ?? "").hasPrefix("mcp-hello") {
            ingestHello(agent: event.agent, installId: event.tool)
            MCPInstaller.recordHello(agent: event.agent, installId: event.tool ?? "")
            let msg = event.message ?? ""
            var clientName = ""
            if let colon = msg.firstIndex(of: ":") {
                clientName = String(msg[msg.index(after: colon)...])
            }
            if clientName.isEmpty, let c = event.cwd { clientName = c }
            if !clientName.isEmpty {
                MCPInstaller.recordClientName(agent: event.agent, clientName: clientName)
            }
            recordRecent(event, gate: .droppedHello)
            return
        }

        // Any non-hello MCP event proves the agent read our rules snippet
        // and called `dc`. This is the second setup gate (rules-honored).
        if event.src == .mcp {
            mcpLastToolCallAt[event.agent] = Date.now
            let snap: [String: Double] = mcpLastToolCallAt.mapValues { $0.timeIntervalSince1970 }
            UserDefaults.standard.set(snap, forKey: "dc.mcpLastToolCallAt")
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
    // end-to-end during Setup — for MCP that means the mcp.py handshake was
    // received (config loaded); for Hook that means the round-trip test
    // succeeded. Both facts are persisted under `dc.configuredAgentIds` and
    // only cleared on explicit Uninstall. This decouples Track-UI enablement
    // from live handshake timing so a previously-verified agent stays
    // tickable across restarts and idle periods.
    func isAgentConfigured(_ id: String) -> Bool {
        if configuredAgentIds.contains(id) { return true }
        // Backwards-compat: an older build may have verified the agent
        // without writing the sticky flag. If its live dicts show both
        // gates, treat as configured and upgrade the flag lazily.
        if let mcp = MCPInstaller.Agent.allCases.first(where: { $0.catalogId == id }) {
            let status = MCPInstaller.status(for: mcp)
            let hasConfig = (status == .live || status == .configWritten || status == .modified)
            if hasConfig && mcpHelloAt[id] != nil {
                return true
            }
        }
        if let hook = HookInstaller.Agent(rawValue: id) {
            if HookInstaller.status(for: hook).isInstalled && (didRoundTrip[id] ?? false) {
                return true
            }
        }
        return false
    }

    /// Called by Setup verify on success (MCP handshake received, or Hook
    /// round-trip completed). Flips the sticky flag so the Track UI enables
    /// immediately and stays enabled across launches.
    func markConfigured(_ agentId: String) {
        guard !configuredAgentIds.contains(agentId) else { return }
        configuredAgentIds.insert(agentId)
        UserDefaults.standard.set(Array(configuredAgentIds), forKey: "dc.configuredAgentIds")
    }

    /// Called by Uninstall to clear the sticky flag so the agent drops out
    /// of the Track list until the user re-runs Setup.
    func unmarkConfigured(_ agentId: String) {
        guard configuredAgentIds.contains(agentId) else { return }
        configuredAgentIds.remove(agentId)
        UserDefaults.standard.set(Array(configuredAgentIds), forKey: "dc.configuredAgentIds")
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
        guard isWatched(session) else {
            Log.gate.info("drop reason=not-watched agent=\(event.agent, privacy: .public) status=\(event.status.rawValue, privacy: .public) target=\(String(describing: self.watchTarget), privacy: .public)")
            recordRecent(event, gate: .droppedNotWatched)
            return
        }

        // Dedup window guard for attention events. Non-attention events always pass.
        if event.status.isAttention {
            let tool = event.tool ?? ""
            let key = "\(session.id)|\(event.status.rawValue)|\(tool)"
            if let last = lastDelivered[key],
               last.status == event.status,
               last.tool == tool,
               now.timeIntervalSince(last.at) < dedupWindow {
                Log.gate.info("drop reason=dedup agent=\(event.agent, privacy: .public) status=\(event.status.rawValue, privacy: .public)")
                recordRecent(event, gate: .droppedDedup)
                return
            }
            lastDelivered[key] = (now, event.status, tool)
        }
        Log.gate.info("accept agent=\(event.agent, privacy: .public) status=\(event.status.rawValue, privacy: .public) session=\(session.id, privacy: .public)")
        Log.deliver.info("fire agent=\(event.agent, privacy: .public) status=\(event.status.rawValue, privacy: .public) attention=\(event.status.isAttention)")
        recordRecent(event, gate: .accepted)
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

    /// Returns the timestamp of the most recent real `dc` tool call from
    /// an MCP agent (anything other than the initialize-time hello).
    /// Presence proves the agent read the rules snippet we installed.
    func lastToolCall(for agent: String) -> Date? {
        mcpLastToolCallAt[agent]
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
