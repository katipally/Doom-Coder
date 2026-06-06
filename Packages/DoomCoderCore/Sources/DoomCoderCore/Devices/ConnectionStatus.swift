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
    /// v6: this side initiated a pairing and is waiting for the other side to
    /// accept. On the Mac: it sent a CSC{requested} / is showing a QR/code/link
    /// and waiting for the iPhone. The row is NOT yet a real connection.
    case awaitingAccept
    /// v6: the iPhone received a CSC{requested} from a Mac and must show the
    /// Accept/Decline prompt. Not yet active.
    case pendingOnPhone

    public var displayName: String {
        switch self {
        case .pending:        return "Pending"
        case .active:         return "Connected"
        case .suspended:      return "Suspended"
        case .removed:        return "Removed"
        case .awaitingAccept: return "Waiting to accept"
        case .pendingOnPhone: return "Pairing request"
        }
    }

    public var isLive: Bool {
        self == .active
    }

    public var isTerminal: Bool {
        self == .removed
    }

    /// True while a handshake is in flight (neither side fully connected yet).
    public var isHandshaking: Bool {
        self == .awaitingAccept || self == .pendingOnPhone || self == .pending
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
             (.pending, .pending),
             (.awaitingAccept, .active),
             (.awaitingAccept, .awaitingAccept),
             (.pendingOnPhone, .active),
             (.pendingOnPhone, .pendingOnPhone):
            return next
        case (_, .removed):
            return .removed
        default:
            return nil
        }
    }
}
