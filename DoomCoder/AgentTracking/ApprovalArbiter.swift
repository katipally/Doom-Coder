// ApprovalArbiter.swift — DoomCoder (Mac)
//
// The universal auto-accept spam fix.
//
// Problem: some agents (Copilot CLI, Cursor, Windsurf — see
// `TrackedAgent.permissionHookReliability == .preDecision`) fire a "permission
// needed" hook BEFORE their own allow-list / auto-approve decision runs. When
// the action is auto-approved the agent never actually blocks, yet DoomCoder
// would have already fired a "needs you" alert — pure spam.
//
// Fix: for pre-decision agents we DEFER the alert by a short, user-tunable
// window (default 0.8s). If, within that window, we see proof the action ran on
// its own (a tool finished, the session ended, etc.), we CANCEL the pending
// alert — the agent was never really waiting. If the window elapses with no
// such proof, the agent is genuinely blocked and we fire the alert.
//
// Reliable agents bypass this entirely (their hook only fires when truly
// blocked), so they keep zero added latency.
//
// Correlation is per-session with a monotonic `ingestSeq`: an event only
// cancels a pending alert if it arrived *after* the permission request
// (seq strictly greater). A session can only block on one permission at a
// time, so session-scoping is correct; the seq guard prevents a stale/late
// event from cancelling a newer request.
//
// Tradeoff (accepted for v1): the timer is in-memory. If the Mac sleeps or the
// app quits during the defer window, a genuinely-blocking alert for a
// pre-decision agent may not fire. Reliable agents are unaffected.

import Foundation
import OSLog

@MainActor
final class ApprovalArbiter {
    static let shared = ApprovalArbiter()

    private let logger = Logger(subsystem: "com.doomcoder", category: "approval")

    private struct Pending {
        let seq: Int
        let task: Task<Void, Never>
    }

    /// sessionKey -> the in-flight deferred alert for that session.
    private var pending: [String: Pending] = [:]

    private init() {}

    // MARK: - Tunable defer window

    private static let defaultDeferSeconds: Double = 0.8
    private static let minDeferSeconds: Double = 0.5
    private static let maxDeferSeconds: Double = 3.0

    /// Per-agent-overridable defer window, clamped to [0.5, 3.0]. Reads
    /// `doomcoder.approval.deferSeconds.<agent>` first, then the global
    /// `doomcoder.approval.deferSeconds`, then the default.
    func deferSeconds(for agent: TrackedAgent) -> Double {
        let ud = UserDefaults.standard
        let perAgentKey = "doomcoder.approval.deferSeconds.\(agent.rawValue)"
        let raw = (ud.object(forKey: perAgentKey) as? Double)
            ?? (ud.object(forKey: "doomcoder.approval.deferSeconds") as? Double)
            ?? Self.defaultDeferSeconds
        return min(max(raw, Self.minDeferSeconds), Self.maxDeferSeconds)
    }

    // MARK: - Schedule / fire

    /// Defer a permission alert for a pre-decision agent. Replaces any existing
    /// pending alert for the same session (a session blocks on one permission
    /// at a time). `fire` is invoked on the main actor if the window elapses
    /// without cancelling evidence.
    func scheduleDeferred(sessionKey: String,
                          agent: TrackedAgent,
                          seq: Int,
                          fire: @escaping @MainActor () -> Void) {
        pending[sessionKey]?.task.cancel()
        let delay = deferSeconds(for: agent)
        logger.info("defer approval alert session=\(sessionKey, privacy: .public) seq=\(seq) delay=\(delay)")
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Only fire if this is still the active pending request.
            guard let cur = self.pending[sessionKey], cur.seq == seq else { return }
            self.pending.removeValue(forKey: sessionKey)
            self.logger.info("approval alert FIRES (genuinely blocked) session=\(sessionKey, privacy: .public) seq=\(seq)")
            fire()
        }
        pending[sessionKey] = Pending(seq: seq, task: task)
    }

    /// Feed every ingested event here. If the event is strong proof that a
    /// pending permission resolved on its own (the action ran, or the session
    /// ended) AND it arrived after the pending request, cancel the deferred
    /// alert. No-op when nothing is pending for the session.
    func noteEvidence(sessionKey: String, seq: Int, phase: NormalizedEventPhase) {
        guard let cur = pending[sessionKey] else { return }
        guard seq > cur.seq else { return }
        guard Self.isResolvingEvidence(phase) else { return }
        logger.info("cancel deferred approval (auto-approved) session=\(sessionKey, privacy: .public) evidence=\(phase.rawValue, privacy: .public) seq=\(seq)")
        cur.task.cancel()
        pending.removeValue(forKey: sessionKey)
    }

    /// Strong evidence that a blocked permission resolved without user action:
    /// a tool completed (ran), or the session/subagent ended. We deliberately
    /// do NOT treat `.toolStart` or generic `.agentResponse` as proof — a
    /// blocked PreToolUse can emit a toolStart and then wait.
    private static func isResolvingEvidence(_ phase: NormalizedEventPhase) -> Bool {
        switch phase {
        case .toolEnd, .toolError, .sessionEnd, .error, .subagentEnd:
            return true
        default:
            return false
        }
    }

    /// Drop any pending alert for a session (e.g. on eviction). Does not fire.
    func clear(sessionKey: String) {
        pending[sessionKey]?.task.cancel()
        pending.removeValue(forKey: sessionKey)
    }
}
