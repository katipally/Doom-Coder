// ConnectionStatus.swift — DoomCoderCore
// State machine for a single Connection between a Mac and an iOS device.
// The state transitions are:
//
//   pending  -- user accepted CKShare -->  active
//   active   -- iOS revoked share    -->  suspended
//   active   -- Mac revoked share    -->  suspended
//   active   -- network error lasting > X  -->  suspended
//   suspended -- user re-accepts    -->  active
//   active   -- user removes        -->  removed
//   suspended -- user removes       -->  removed
//   removed  -- terminal, no transitions
//
// The Mac side and iOS side each compute their own status. A connection is
// considered "active" only when BOTH sides report active. A single-side
// suspended is enough to halt pushes.

import Foundation

public enum ConnectionStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case pending
    case active
    case suspended
    case removed

    public var displayName: String {
        switch self {
        case .pending:   return "Pending"
        case .active:    return "Connected"
        case .suspended: return "Suspended"
        case .removed:   return "Removed"
        }
    }

    public var isLive: Bool {
        self == .active
    }

    public var isTerminal: Bool {
        self == .removed
    }

    /// Returns the result of applying a transition. Returns nil if the
    /// transition is not legal. `removed` is terminal -- nothing leaves it.
    public func transitioned(to next: ConnectionStatus) -> ConnectionStatus? {
        if self == .removed { return nil }
        switch (self, next) {
        case (.pending, .active),
             (.active, .suspended),
             (.active, .active),
             (.suspended, .active),
             (.suspended, .suspended),
             (.pending, .pending):
            return next
        case (_, .removed):
            return .removed
        default:
            return nil
        }
    }
}
