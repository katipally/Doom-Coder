import Foundation
import Observation

// MARK: - AgentStatusManager
//
// Central state machine that consumes events from SocketServer (MCP + legacy hook
// wire format) and keeps a list of live sessions. Drives every downstream effect:
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

    // Sessions with no events for this long trigger an informational inactivity
    // banner. v1.8.1: raised from 30min → 2h and the reaper no longer force-
    // closes sessions (real agent sessions routinely idle for hours between
    // turns, and the "timed out" wording alarmed users). The reaper now only
    // emits an informational ping with an interactive "End session" action.
    let staleTimeout: TimeInterval = 2 * 60 * 60

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
    // Sticky "this agent finished setup successfully at least once" flag.
    // Persisted under `dc.configuredAgentIds`. Only cleared on explicit
    // Uninstall. Decouples the Track UI from live handshake state so a
    // previously-verified agent stays tickable across restarts / idle periods.
    @ObservationIgnored private(set) var configuredAgentIds: Set<String> = []
    // v1.8.1: per-session timestamp of the last inactivity ping we emitted.
    // Prevents the reaper from firing a "Session inactive 2h+" banner every
    // 60s — we re-ping only after another staleTimeout window has elapsed.
    @ObservationIgnored private var lastInactivityPingAt: [String: Date] = [:]
    @ObservationIgnored nonisolated(unsafe) private var _reaperTimer: Timer?

    // Round-trip test continuations keyed by nonce. Reserved for future MCP
    // round-trip tests; currently unused (MCPRoundTripTest polls mcpHelloAt
    // directly rather than via continuations).
    @ObservationIgnored private var roundTripWaiters: [String: CheckedContinuation<AgentEvent, Never>] = [:]

    // MARK: - Init / Deinit

    init() {
        // v1.8: replaced WatchTarget (.none/.all/.agentType) with a
        // per-agent Set<String>. Migration from the old Data-encoded key
        // lives in LegacyDefaults.migrate(); by the time we get here, only
        // the new key should exist.
        let ud = UserDefaults.standard
        if let arr = ud.array(forKey: "dc.watchedAgentIds") as? [String] {
            self.watchedAgentIds = Set(arr)
        } else {
            self.watchedAgentIds = []
        }

        // Restore the per-agent "configured" flags. Any missing entry means
        // the agent has never been verified → not configured yet.
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
        // Real event arrived → reset the inactivity ping cooldown for this
        // session so the reaper starts its 2h clock afresh.
        if let sid = event.sessionId { lastInactivityPingAt.removeValue(forKey: sid) }

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

    // v1.8: per-agent tracking toggles. An agent fires notifications only if
    //   • it's in watchedAgentIds, AND
    //   • it's configured (see isAgentConfigured).
    // The menubar and the Configure sidebar both present these as per-agent
    // toggles bound directly to this set.
    var watchedAgentIds: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(watchedAgentIds),
                                      forKey: "dc.watchedAgentIds")
        }
    }

    // MARK: - Configured-agent helpers

    // An agent counts as "configured" once the user has proven their wiring
    // end-to-end during Setup — the mcp.py handshake was received (config
    // loaded) at least once. Persisted under `dc.configuredAgentIds` and
    // only cleared on explicit Uninstall. This decouples Track-UI
    // enablement from live handshake timing so a previously-verified agent
    // stays tickable across restarts and idle periods.
    func isAgentConfigured(_ id: String) -> Bool {
        if configuredAgentIds.contains(id) { return true }
        // Backwards-compat: an older build may have verified the agent
        // without writing the sticky flag. If its live dicts show the
        // handshake, treat as configured.
        if let mcp = MCPInstaller.Agent.allCases.first(where: { $0.catalogId == id }) {
            let status = MCPInstaller.status(for: mcp)
            let hasConfig = (status == .live || status == .configWritten || status == .modified)
            if hasConfig && mcpHelloAt[id] != nil {
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

    // Called by HookRoundTripTest on success (legacy path, removed in v1.8).
    // Retained as a no-op stub only if any dead call site remains; otherwise
    // this method is unused.
    func markRoundTripSuccess(agentId: String) {
        // v1.8: hooks removed; MCP path calls markConfigured directly.
        markConfigured(agentId)
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
    // pipeline. v1.8: per-agent gate — the agent must be in watchedAgentIds
    // AND configured. "Configured but not watched" is explicitly silent
    // (user turned it off); "watched but not configured" is guarded so a
    // stale toggle from before Uninstall doesn't leak through.
    func isWatched(_ session: AgentSession) -> Bool {
        guard watchedAgentIds.contains(session.agent) else { return false }
        return isAgentConfigured(session.agent)
    }

    private func deliver(_ session: AgentSession, event: AgentEvent, now: Date) {
        // Strict watch filter: drop everything not matching the user's
        // selection from the menubar. The session row still updates (so
        // the sidebar is honest about what's happening), but no banner,
        // iPhone push, or sleep-extend fires for unwatched sessions.
        guard isWatched(session) else {
            Log.gate.info("drop reason=not-watched agent=\(event.agent, privacy: .public) status=\(event.status.rawValue, privacy: .public) watched=\(self.watchedAgentIds.count, privacy: .public)")
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
        // v1.8.1: no longer auto-closes sessions. Emits an informational
        // "Session inactive 2h+" event with an interactive "End session"
        // action on the iOS / macOS notification. The session stays `.running`
        // in the UI until the user explicitly ends it (or the agent pings
        // again, at which point inactivity pings reset).
        let now = Date.now
        for s in sessions where s.state != .done {
            guard now.timeIntervalSince(s.lastEventAt) > staleTimeout else { continue }
            let lastPing = lastInactivityPingAt[s.id] ?? .distantPast
            guard now.timeIntervalSince(lastPing) > staleTimeout else { continue }

            lastInactivityPingAt[s.id] = now
            let hours = Int(staleTimeout / 3600)
            let synthetic = AgentEvent(
                src: s.source,
                agent: s.agent,
                status: .info,
                sessionId: s.id,
                cwd: s.cwd,
                message: "Session inactive \(hours)h+ — still tracking. Tap to end."
            )
            // Mark so NotificationManager routes it as an interactive
            // inactivity banner (info events are normally silent).
            onSessionUpdated?(s, synthetic)
        }
    }

    /// User-initiated end. Marks the session `.done` and removes it from the
    /// watched set (so we stop pulling iPhone notifications). Called by the
    /// "End session" notification action and by any future UI affordance.
    func endSession(id: String) {
        guard let idx = sessionsById[id] else { return }
        var s = sessions[idx]
        guard s.state != .done else { return }
        s.state = .done
        sessions[idx] = s
        lastInactivityPingAt.removeValue(forKey: id)
        let synthetic = AgentEvent(
            src: s.source,
            agent: s.agent,
            status: .done,
            sessionId: s.id,
            cwd: s.cwd,
            message: "Ended by user"
        )
        onSessionUpdated?(s, synthetic)
        schedulePrune(sessionId: s.id, delay: 1)
        recomputeActivity()
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
