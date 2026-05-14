import Foundation
import Observation

// Builds MapProjectCluster tree from live AgentTrackingManager sessions.
// History mode queries EventStore and reconstructs the same structure.

@Observable
@MainActor
final class SessionMapViewModel {

    var clusters: [MapProjectCluster] = []
    var selectedEventID: UUID? = nil
    var selectedEvent: MapEventNode? = nil

    // Flat lookup so NodeDetailPanel can find an event by UUID fast.
    private var eventByID: [UUID: MapEventNode] = [:]

    // Called by SessionMapView whenever sessions change.
    func refresh(sessions: [String: AgentTrackingManager.Session]) {
        var byProject: [String: [MapSessionLane]] = [:]
        var newEventByID: [UUID: MapEventNode] = [:]

        for (key, session) in sessions {
            let lane = buildLane(from: session, sessionKey: key, eventByID: &newEventByID)
            let display = abbreviatePath(session.cwd.isEmpty ? "~" : session.cwd)
            byProject[display, default: []].append(lane)
        }

        eventByID = newEventByID
        clusters = byProject.map { cwd, lanes in
            MapProjectCluster(
                id: cwd, cwd: cwd,
                sessions: lanes.sorted { $0.startTime < $1.startTime }
            )
        }.sorted { $0.cwd < $1.cwd }

        // Refresh selected event reference (content may have changed).
        if let sid = selectedEventID { selectedEvent = eventByID[sid] }
    }

    func selectEvent(id: UUID) {
        selectedEventID = id
        selectedEvent = eventByID[id]
    }

    func clearSelection() {
        selectedEventID = nil
        selectedEvent = nil
    }

    // MARK: - Lane builder

    private func buildLane(
        from session: AgentTrackingManager.Session,
        sessionKey: String,
        eventByID: inout [UUID: MapEventNode]
    ) -> MapSessionLane {
        var cycles: [MapPromptCycle] = []
        var cycleEvents: [MapEventNode] = []
        var cycleStart = session.startedAt

        for te in session.events {
            // A userPrompt event closes the previous cycle and starts a new one.
            if te.phase == .userPrompt, !cycleEvents.isEmpty {
                cycles.append(MapPromptCycle(id: UUID(), startTime: cycleStart, events: cycleEvents))
                cycleEvents = []
                cycleStart = te.timestamp
            }
            let node = MapEventNode(
                id: te.id,
                event: te.event,
                phase: te.phase,
                tool: te.tool,
                timestamp: te.timestamp,
                summary: te.summary,
                rawPayload: te.rawPayload
            )
            cycleEvents.append(node)
            eventByID[node.id] = node
        }
        if !cycleEvents.isEmpty {
            cycles.append(MapPromptCycle(id: UUID(), startTime: cycleStart, events: cycleEvents))
        }

        return MapSessionLane(
            id: sessionKey,
            agent: session.agent,
            sessionKey: sessionKey,
            cwd: session.cwd,
            startTime: session.startedAt,
            endTime: (session.hasEnded || session.hasFailed) ? session.updatedAt : nil,
            promptCycles: cycles,
            isLive: session.isLive,
            isActive: session.isActiveWindow,
            displayState: session.displayState
        )
    }

    // MARK: - Helpers

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}
