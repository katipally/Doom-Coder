import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// ActivityKit attributes for a DoomCoder Live Activity (one per live session).
///
/// Static fields (fixed for the life of the activity):
///   sessionKey — stable identifier used to locate the activity on update/end
///   agent      — TrackedAgent.rawValue (for icon + label)
///   macId      — identifies which Mac the session belongs to
///
/// ContentState (updated as the session progresses):
///   All mutable fields are Sendable and Hashable so ActivityKit can diff them.
@available(iOS 16.1, *)
public struct DoomCoderActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var displayState: String
        public var lastPhase: String
        public var lastTool: String?
        public var toolCallCount: Int
        public var elapsedSeconds: Int
        public var awaitingPermission: Bool
        public var agentDisplayName: String
        public var cwdBase: String?

        public init(displayState: String,
                    lastPhase: String,
                    lastTool: String? = nil,
                    toolCallCount: Int,
                    elapsedSeconds: Int,
                    awaitingPermission: Bool,
                    agentDisplayName: String,
                    cwdBase: String? = nil) {
            self.displayState     = displayState
            self.lastPhase        = lastPhase
            self.lastTool         = lastTool
            self.toolCallCount    = toolCallCount
            self.elapsedSeconds   = elapsedSeconds
            self.awaitingPermission = awaitingPermission
            self.agentDisplayName = agentDisplayName
            self.cwdBase          = cwdBase
        }
    }

    public var sessionKey: String
    public var agent: String
    public var macId: String

    public init(sessionKey: String, agent: String, macId: String) {
        self.sessionKey = sessionKey
        self.agent      = agent
        self.macId      = macId
    }
}
#endif // canImport(ActivityKit) && os(iOS)
