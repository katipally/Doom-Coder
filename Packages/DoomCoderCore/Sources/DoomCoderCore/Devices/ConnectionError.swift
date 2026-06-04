// ConnectionError.swift — DoomCoderCore
// All user-visible errors raised by the pairing / connection machinery.
// Each case carries a `userMessage` string safe to display in alerts and
// dialogs. The technical `errorDescription` is for logs and diagnostics.

import Foundation

public enum ConnectionError: LocalizedError, Sendable, Equatable {
    case iCloudUnavailable
    case shareCreationFailed(String)
    case shareAcceptanceFailed(String)
    case shareRevoked
    case zoneNotFound
    case participantLookupFailed(String)
    case invalidPairingCode
    case pairingCodeExpired
    case alreadyPaired
    case persistenceFailed(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud is not available. Sign in to iCloud in System Settings and try again."
        case .shareCreationFailed(let detail):
            return "Couldn't create the iCloud share: \(detail)"
        case .shareAcceptanceFailed(let detail):
            return "Couldn't accept the iCloud share: \(detail)"
        case .shareRevoked:
            return "The iCloud share was revoked. Ask the Mac to re-share, or re-pair from the Mac."
        case .zoneNotFound:
            return "The DoomCoder zone wasn't found in iCloud."
        case .participantLookupFailed(let detail):
            return "Couldn't find the iPhone in the iCloud share: \(detail)"
        case .invalidPairingCode:
            return "That pairing code isn't valid. Scan the QR or re-enter the code on the Mac."
        case .pairingCodeExpired:
            return "That pairing code expired. Ask the Mac to regenerate it."
        case .alreadyPaired:
            return "This device is already paired with that Mac."
        case .persistenceFailed(let detail):
            return "Couldn't save the connection locally: \(detail)"
        case .unknown(let detail):
            return "Unexpected error: \(detail)"
        }
    }

    public var userMessage: String {
        errorDescription ?? "An unknown error occurred."
    }
}
