import Foundation

// Data model for the Session Map canvas.
// Built from live AgentTrackingManager sessions (or EventStore rows for history).

struct MapProjectCluster: Identifiable, Equatable {
    let id: String          // display CWD (tilde-abbreviated)
    let cwd: String         // display CWD
    var sessions: [MapSessionLane]
}

struct MapSessionLane: Identifiable, Equatable {
    let id: String          // sessionKey ("agent::sessionId")
    let agent: TrackedAgent
    let sessionKey: String
    let cwd: String
    let startTime: Date
    var endTime: Date?
    var promptCycles: [MapPromptCycle]
    var isLive: Bool
    var isActive: Bool      // frontmost IDE window matches this session
    var displayState: AgentSessionState
}

struct MapPromptCycle: Identifiable, Equatable {
    let id: UUID
    let startTime: Date
    var events: [MapEventNode]
    var endTime: Date { events.last?.timestamp ?? startTime }
    var status: MapNodeStatus {
        if events.contains(where: { $0.phase == .error || $0.phase == .toolError }) { return .error }
        if events.contains(where: { $0.phase == .permissionNeeded }) { return .waiting }
        if events.contains(where: { $0.phase == .sessionEnd }) { return .done }
        if events.contains(where: { $0.phase == .agentResponse }) { return .done }
        return .running
    }
}

struct MapEventNode: Identifiable, Equatable {
    let id: UUID
    let event: String
    let phase: NormalizedEventPhase
    let tool: String?
    let timestamp: Date
    let summary: String
    let rawPayload: String?  // populated from EventStore for history mode
}

enum MapNodeStatus: Equatable {
    case running, done, error, waiting, unknown
}
