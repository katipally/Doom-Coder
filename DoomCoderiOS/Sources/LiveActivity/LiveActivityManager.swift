import Foundation
@preconcurrency import ActivityKit

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activities: [String: Activity<DoomCoderActivityAttributes>] = [:]
    private init() {}

    func update(with agg: CKSessionAggregate) async {
        let maxConcurrent = IOSUserSettings.shared.liveActivityMaxConcurrent
        let elapsed = Int(Date().timeIntervalSince(agg.startedAt))
        let state = DoomCoderActivityAttributes.ContentState(
            status: agg.status.rawValue,
            currentTool: agg.currentTool,
            toolCount: agg.totalToolCalls,
            elapsedSec: elapsed,
            approvalPending: agg.status == .waitingApproval,
            toolArgsPreview: nil,
            requestId: agg.pendingRequestId,
            toolDetail: agg.currentTool
        )

        switch agg.status {
        case .running, .waitingApproval:
            if let activity = activities[agg.sessionKey] {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            } else if activities.count < maxConcurrent {
                await start(agg: agg, initialState: state)
            }
        case .completed, .failed:
            await end(sessionKey: agg.sessionKey, finalState: state)
        }
    }

    private func start(agg: CKSessionAggregate, initialState: DoomCoderActivityAttributes.ContentState) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = DoomCoderActivityAttributes(
            sessionKey: agg.sessionKey,
            agent: agg.agent,
            cwdBasename: agg.cwdBasename,
            agentColorHex: Self.brandColorHex(for: agg.agent)
        )
        do {
            let act = try Activity.request(attributes: attrs,
                                           content: ActivityContent(state: initialState, staleDate: nil),
                                           pushType: nil)
            activities[agg.sessionKey] = act
        } catch {
            // activity start can fail (budget/permissions); ignore
        }
    }

    private func end(sessionKey: String, finalState: DoomCoderActivityAttributes.ContentState) async {
        guard let activity = activities[sessionKey] else { return }
        let dismissSec = TimeInterval(IOSUserSettings.shared.liveActivityAutoDismissSec)
        let dismissAt = Date().addingTimeInterval(dismissSec)
        await activity.end(ActivityContent(state: finalState, staleDate: nil),
                           dismissalPolicy: .after(dismissAt))
        activities.removeValue(forKey: sessionKey)
    }

    func endAll() async {
        for (key, act) in activities {
            await act.end(nil, dismissalPolicy: .immediate)
            activities.removeValue(forKey: key)
        }
    }

    // Returns the brand hex color string for an agent (used by the widget for keylineTint).
    static func brandColorHex(for agent: String) -> String {
        switch agent {
        case "claude":      return "#E06B37"
        case "copilot_cli": return "#2088FF"
        case "cursor":      return "#6B46C1"
        case "windsurf":    return "#0FBBDD"
        case "codex_cli":   return "#22C55E"
        case "vscode":      return "#5A7FA6"
        default:            return "#888888"
        }
    }
}
