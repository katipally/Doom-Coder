import Foundation

/// Unified event phase taxonomy across all AI agents. Mirror of the Mac-side
/// enum; CloudKit sync uses the rawValue String.
public enum NormalizedEventPhase: String, Codable, Sendable, CaseIterable {
    case sessionStart
    case sessionEnd
    case userPrompt
    case toolStart
    case toolEnd
    case toolError
    case permissionNeeded
    case agentResponse
    case subagentStart
    case subagentEnd
    case error
    case other
    // Opt-in coverage phases (default OFF in the gate). Added so events that
    // were previously dropped to `.other` can become notifiable. New cases
    // MUST be mirrored byte-identically in the Mac-side enum
    // (DoomCoder/AgentTracking/AgentEventNormalizer.swift).
    case fileEdit
    case compaction
    case thinking
    case housekeeping

    /// iOS interruption-level mapping (used by NSE to set
    /// `UNNotificationContent.interruptionLevel`).
    public var iOSInterruptionLevel: InterruptionLevel {
        switch self {
        case .permissionNeeded, .toolError, .error:
            return .timeSensitive
        case .sessionEnd:
            return .active
        case .sessionStart, .subagentStart, .subagentEnd,
             .toolStart, .toolEnd, .agentResponse, .userPrompt, .other,
             .fileEdit, .compaction, .thinking, .housekeeping:
            return .passive
        }
    }

    public enum InterruptionLevel: String, Sendable {
        case passive
        case active
        case timeSensitive
        case critical
    }
}
