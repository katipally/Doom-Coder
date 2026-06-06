// IosDeviceId.swift — DoomCoder Companion
// Stable per-iOS-device identifier, written into PeerStatus records
// so the Mac can identify which iPhone is paired.
//
// v2.7: replaces the ad-hoc `DeviceIDFactory.make()` calls scattered
// around IOSPairingCoordinator that were generating a *fresh* random
// id every time, which made the Mac unable to track the same iPhone
// across launches.
//
// v5: persisted to iCloud Keychain (kSecAttrSynchronizable = true)
// so an uninstall + reinstall of the app on the same iCloud account
// returns the same identifier. Falls back to App Group UserDefaults
// if iCloud Keychain is unavailable, then to a fresh random id. The
// install-restore path is the fix for the "Mac shows connected but
// iPhone doesn't" bug: with v2.7 the iOS app would generate a new id
// on every reinstall and the Mac-side Connection would be orphaned.

import Foundation
import Security
import UIKit
import CloudKit
import DoomCoderCore

@MainActor
enum IosDeviceId {
    private static let defaultsKey = "doomcoder.ios.deviceId.v1"
    private static let keychainService = "com.doomcoder.app.companion.deviceId"
    private static let keychainAccount = "iosDeviceId.v1"
    private static let userRecordKey = "doomcoder.ios.userRecordName.v1"

    /// The current iCloud account's `CKUserRecordID.recordName`, memoized in
    /// the App Group. This is the canonical, stable identifier for *which
    /// Apple ID this is* — used to decide same-vs-different iCloud during
    /// pairing (comparing against the share owner's record name) instead of
    /// the racy `CKShare.Metadata.participantRole`, which can momentarily
    /// report a non-owner role before the share fully propagates.
    static func iCloudUserRecordName() async -> String? {
        if let cached = AppGroupCache.defaults.string(forKey: userRecordKey), !cached.isEmpty {
            return cached
        }
        do {
            let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
            let id = try await container.userRecordID()
            AppGroupCache.defaults.set(id.recordName, forKey: userRecordKey)
            return id.recordName
        } catch {
            return nil
        }
    }

    /// Synchronous read of the cached record name (nil if not yet fetched).
    static var cachedICloudUserRecordName: String? {
        let v = AppGroupCache.defaults.string(forKey: userRecordKey)
        return (v?.isEmpty == false) ? v : nil
    }

    /// Invalidate the cached user-record name (call on `.CKAccountChanged`
    /// so a sign-out/switch doesn't leave a stale account identity).
    static func invalidateICloudUserRecordName() {
        AppGroupCache.defaults.removeObject(forKey: userRecordKey)
    }

    /// The stable per-install iOS identifier. Resolution order:
    ///   1. iCloud Keychain (kSecAttrSynchronizable = true) — survives
    ///      uninstall + reinstall on the same iCloud account.
    ///   2. App Group UserDefaults — survives a normal relaunch.
    ///   3. `UIDevice.identifierForVendor`, hashed to our 22-char
    ///      DeviceID format. `identifierForVendor` is stable across
    ///      reinstalls of the same app vendor but only for as long as
    ///      any app from the vendor is installed; on a true fresh
    ///      install with no other DoomCoder apps present it can change.
    ///   4. A fresh random DeviceID. This is the "last resort" — the
    ///      Mac will see a brand-new iPhone and either auto-attach
    ///      (same Apple ID) or wait for a QR re-pair.
    static var current: DeviceID {
        if let kc = loadFromKeychain() { return kc }
        if let ud = AppGroupCache.defaults.string(forKey: defaultsKey), !ud.isEmpty {
            // Promote to iCloud Keychain so a future uninstall+reinstall
            // also restores this id.
            try? saveToKeychain(ud)
            return ud
        }
        let newId: DeviceID = {
            if let vendorId = UIDevice.current.identifierForVendor?.uuidString,
               DeviceIDFactory.isValid(mapVendorId(vendorId)) {
                return mapVendorId(vendorId)
            }
            return DeviceIDFactory.make()
        }()
        AppGroupCache.defaults.set(newId, forKey: defaultsKey)
        try? saveToKeychain(newId)
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

    // MARK: - iCloud Keychain helpers

    private static func loadFromKeychain() -> DeviceID? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty
        else { return nil }
        return str
    }

    private static func saveToKeychain(_ id: DeviceID) throws {
        let data = Data(id.utf8)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        // SecItemAdd is fine to call repeatedly — the OS upserts.
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Update existing entry.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount,
                kSecAttrSynchronizable as String: kCFBooleanTrue!,
            ]
            let updates: [String: Any] = [
                kSecValueData as String: data,
            ]
            _ = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        } else if addStatus != errSecSuccess {
            throw NSError(domain: "IosDeviceId", code: Int(addStatus))
        }
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
