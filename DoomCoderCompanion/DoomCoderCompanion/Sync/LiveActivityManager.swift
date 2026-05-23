// LiveActivityManager.swift — DoomCoder Companion
// Manages ActivityKit Live Activities (iOS 16.1+). One activity per live
// session, keyed by sessionKey. Called from CompanionSyncEngine when a
// Session record is upserted or ends.

import Foundation
import DoomCoderCore

#if canImport(ActivityKit) && os(iOS)
@preconcurrency import ActivityKit

@available(iOS 16.1, *)
@MainActor
final class LiveActivityManager {

    static let shared = LiveActivityManager()
    private init() {}

    /// sessionKey → active Activity
    private var activities: [String: Activity<DoomCoderActivityAttributes>] = [:]

    // MARK: - Public API

    /// Called when a Session record is upserted. Creates the Live Activity
    /// on first call for a sessionKey; updates it on subsequent calls.
    func update(_ session: SessionRecord) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let elapsed = Int(Date().timeIntervalSince(session.startedAt))
        let state = DoomCoderActivityAttributes.ContentState(
            displayState:      session.displayState,
            lastTool:          session.lastTool,
            toolCallCount:     session.toolCallCount,
            elapsedSeconds:    elapsed,
            awaitingPermission: session.awaitingPermission,
            agentDisplayName:  TrackedAgent(rawValue: session.agent)?.displayName ?? session.agent,
            cwdBase:           session.cwdBase
        )

        if let existing = activities[session.sessionKey] {
            await existing.update(ActivityContent(state: state, staleDate: nil))
        } else {
            let attrs = DoomCoderActivityAttributes(
                sessionKey: session.sessionKey,
                agent:      session.agent,
                macId:      session.macId
            )
            do {
                let activity = try Activity.request(
                    attributes: attrs,
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
                activities[session.sessionKey] = activity
            } catch {
                print("[LiveActivityManager] request failed for \(session.sessionKey): \(error)")
            }
        }
    }

    /// Called when a session ends or fails. Dismisses the Live Activity
    /// after a short grace period so the user can see the final state.
    func end(sessionKey: String) async {
        guard let activity = activities.removeValue(forKey: sessionKey) else { return }
        await activity.end(nil, dismissalPolicy: .after(.now + 5))
    }

    /// Ends all active Live Activities. Call on account switch or sign-out.
    func endAll() async {
        let keys = Array(activities.keys)
        for key in keys {
            if let activity = activities.removeValue(forKey: key) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
#endif // canImport(ActivityKit) && os(iOS)
