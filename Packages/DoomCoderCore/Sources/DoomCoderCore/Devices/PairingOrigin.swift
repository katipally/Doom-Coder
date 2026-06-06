// PairingOrigin.swift — DoomCoderCore
// How a Connection came into existence. Drives the DeviceDetailView
// "Pairing origin" row and the per-row label in the Devices section.
// v5: was previously implicit (the codebase only created Connections
// through one of three explicit flows: QR scan, code entry, or link
// paste). With the v5 same-Apple-ID auto-attach path we now have a
// fourth origin ("auto") and a fifth ("reinstall" — see PR2/§6.6).
// Stored locally only; not part of the CloudKit record schema.

import Foundation

public enum PairingOrigin: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// The user scanned a QR code displayed on the Mac.
    case qr
    /// The user typed the 6-character pairing code shown on the Mac.
    case code
    /// The user pasted a doomcoder://pair?ckShareURL=… link.
    case link
    /// Auto-attached by the iOS app on the first MacStatus heartbeat
    /// because the iPhone and Mac share the same Apple ID. No user
    /// action required; the inline banner explains the situation.
    case auto
    /// The iOS app was reinstalled and reconciled an existing
    /// Mac-side Connection via the iCloud Keychain-restored
    /// iosDeviceId (or, failing that, the ConnectionStateChange
    /// {reinstall-detected} fast path).
    case reinstall
    /// Imported from a backup / migration. UI shows "Imported" so
    /// the user knows no fresh handshake happened on this device.
    case imported
    /// v6: Mac-initiated same-iCloud pairing (the Mac picked this iPhone in
    /// its AirDrop-style "Same iCloud" list and the user accepted on the phone).
    case sameICloud

    public var displayName: String {
        switch self {
        case .qr:         return "QR code"
        case .code:       return "Typed code"
        case .link:       return "Pairing link"
        case .auto:       return "Auto (same Apple ID)"
        case .reinstall:  return "Reinstalled app"
        case .imported:   return "Imported"
        case .sameICloud: return "Same iCloud"
        }
    }

    public var systemImage: String {
        switch self {
        case .qr:         return "qrcode.viewfinder"
        case .code:       return "keyboard"
        case .link:       return "link"
        case .auto:       return "icloud"
        case .reinstall:  return "arrow.clockwise.circle"
        case .imported:   return "tray.and.arrow.down"
        case .sameICloud: return "person.2.fill"
        }
    }
}
