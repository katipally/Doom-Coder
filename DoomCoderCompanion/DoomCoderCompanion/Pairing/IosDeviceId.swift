// IosDeviceId.swift — DoomCoder Companion
// Stable per-iOS-device identifier, written into PeerStatus records
// so the Mac can identify which iPhone is paired. Persisted to
// UserDefaults so it survives uninstall/reinstall only if iCloud Keychain
// restores the App Group; in practice a fresh install gets a new id
// (acceptable — the Mac will simply create a new Connection record
// for it).
//
// v2.7: replaces the ad-hoc `DeviceIDFactory.make()` calls scattered
// around IOSPairingCoordinator that were generating a *fresh* random
// id every time, which made the Mac unable to track the same iPhone
// across launches.

import Foundation
import UIKit
import DoomCoderCore

@MainActor
enum IosDeviceId {
    private static let defaultsKey = "doomcoder.ios.deviceId.v1"

    /// The stable per-install iOS identifier. Reads from UserDefaults;
    /// if absent, derives from `UIDevice.identifierForVendor` and
    /// falls back to a freshly-generated DeviceID.
    static var current: DeviceID {
        if let stored = AppGroupCache.defaults.string(forKey: defaultsKey), !stored.isEmpty {
            return stored
        }
        let newId: DeviceID = {
            if let vendorId = UIDevice.current.identifierForVendor?.uuidString,
               DeviceIDFactory.isValid(mapVendorId(vendorId)) {
                return mapVendorId(vendorId)
            }
            return DeviceIDFactory.make()
        }()
        AppGroupCache.defaults.set(newId, forKey: defaultsKey)
        return newId
    }

    /// Stable per-iOS-display name. Reads from `UIDevice.current.name`
    /// (the user-set iPhone name) so the Mac can show "Yash's iPhone"
    /// in its Connections list.
    static var displayName: String {
        let name = UIDevice.current.name
        return name.isEmpty ? "iPhone" : name
    }

    static var model: String {
        UIDevice.current.model
    }

    static var systemName: String {
        UIDevice.current.systemName + " " + UIDevice.current.systemVersion
    }

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// Apple guarantees `identifierForVendor` is the same for all apps
    /// from the same vendor on the same device, but its value is a
    /// 32-char UUID, not the 22-char base64url we use elsewhere. We
    /// hash it deterministically into a 22-char DeviceID so the
    /// identifiers all look uniform in the Mac's diagnostic view.
    private static func mapVendorId(_ uuid: String) -> DeviceID {
        let bytes = Array(uuid.utf8)
        let sha = bytes.reduce(into: [UInt8](repeating: 0, count: 16)) { acc, b in
            acc[0] = (acc[0] &+ b) & 0xFF
            acc[acc.count - 1] = (acc[acc.count - 1] ^ b) & 0xFF
        }
        return Data(sha).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
