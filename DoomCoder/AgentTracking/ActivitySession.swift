import Foundation
import SwiftUI

// MARK: - ActivitySession
//
// The unified session model behind the Activity tab. It is *reconstructed from
// the raw events table* (`EventStore.reconstructedSessions`) so that nothing is
// ever dropped — sessions that never ended cleanly (IDE quit directly, the app
// restarted mid-session, a crash/sleep) still appear, badged `.incomplete`.
//
// Three sources are merged, in priority order:
//   1. EventStore.reconstructedSessions()        — the base; never lossy.
//   2. EventStore.recentSessionHistory()         — authoritative outcome/counts
//                                                   when a curated row exists.
//   3. AgentTrackingManager.shared.liveSessions  — in-progress (overrides to
//                                                   `.running`, pins to top).

enum ActivityOutcome: String, Sendable {
    case running        // live, in-progress
    case completed      // ended cleanly
    case failed         // fatal error / tool error
    case incomplete     // no clean end and not live (abandoned / orphaned)

    var label: String {
        switch self {
        case .running:    return "Running"
        case .completed:  return "Completed"
        case .failed:     return "Failed"
        case .incomplete: return "Incomplete"
        }
    }

    var symbol: String {
        switch self {
        case .running:    return "circle.fill"
        case .completed:  return "checkmark.circle.fill"
        case .failed:     return "xmark.octagon.fill"
        case .incomplete: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .running:    return .accentColor
        case .completed:  return .green
        case .failed:     return .red
        case .incomplete: return .orange
        }
    }
}

struct ActivitySession: Identifiable, Sendable {
    let sessionKey: String
    let agentKey: String
    let agent: TrackedAgent?
    let startedAt: Date
    let endedAt: Date
    let eventCount: Int
    let toolCount: Int
    let permissionCount: Int
    let subagentCount: Int
    let outcome: ActivityOutcome
    let isLive: Bool
    let hasNotifications: Bool

    var id: String { sessionKey }
    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    var displayName: String { agent?.displayName ?? agentKey }

    /// Sort key: live sessions float to the very top, then reverse-chron by end.
    var sortKey: Date { isLive ? .distantFuture : endedAt }
}

// MARK: - Builder

enum ActivitySessionBuilder {
    /// Builds the merged session list. Pass an agent key to scope to one agent,
    /// or nil for all agents (the "All Activity" aggregate).
    @MainActor
    static func build(agentFilter: String? = nil, limit: Int = 200) -> [ActivitySession] {
        let reconstructed = EventStore.shared.reconstructedSessions(agent: agentFilter, limit: limit)

        // Index curated history by session_key for authoritative outcome/counts.
        var history: [String: EventStore.SessionHistoryEntry] = [:]
        for h in EventStore.shared.recentSessionHistory(agent: agentFilter, limit: 500) {
            history[h.sessionKey] = h
        }

        // Live sessions (in-memory) override to .running and pin to the top.
        let live = AgentTrackingManager.shared.liveSessions
        let liveKeys = Set(live.map(\.id))

        // Which sessions produced at least one notification (for the 🔔 badge).
        let notifs = agentFilter != nil
            ? EventStore.shared.recentNotifications(agent: agentFilter!, limit: 1000)
            : EventStore.shared.recentNotifications(limit: 1000)
        let notifiedKeys = Set(notifs.map(\.sessionKey))

        return reconstructed.map { r in
            let isLive = liveKeys.contains(r.sessionKey)
            let h = history[r.sessionKey]
            let outcome = deriveOutcome(isLive: isLive, history: h, hasEnd: r.hasEnd, hasError: r.hasError)
            return ActivitySession(
                sessionKey: r.sessionKey,
                agentKey: r.agent,
                agent: TrackedAgent(rawValue: r.agent),
                startedAt: h?.startedAt ?? r.startedAt,
                endedAt: h?.endedAt ?? r.endedAt,
                eventCount: r.eventCount,
                toolCount: max(r.toolCount, h?.toolCount ?? 0),
                permissionCount: max(r.permissionCount, h?.permissionCount ?? 0),
                subagentCount: h?.subagentCount ?? 0,
                outcome: outcome,
                isLive: isLive,
                hasNotifications: notifiedKeys.contains(r.sessionKey)
            )
        }
        .sorted { $0.sortKey > $1.sortKey }
    }

    private static func deriveOutcome(isLive: Bool,
                                      history: EventStore.SessionHistoryEntry?,
                                      hasEnd: Bool,
                                      hasError: Bool) -> ActivityOutcome {
        if isLive { return .running }
        if let h = history {
            switch h.outcome {
            case "failed":   return .failed
            case "reverted": return .incomplete   // soft-reverted = abandoned/idle
            default:         return .completed     // "completed"
            }
        }
        if hasEnd { return .completed }
        if hasError { return .failed }
        return .incomplete
    }
}
