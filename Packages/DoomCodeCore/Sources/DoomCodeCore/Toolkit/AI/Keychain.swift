// Keychain.swift — DoomCodeCore
// Minimal Keychain wrapper for storing the user's BYO API key securely. The key
// never leaves the device except as the Authorization header on requests the
// user explicitly triggers to their chosen provider. Local-only — never synced
// (uses ...ThisDeviceOnly accessibility, no kSecAttrSynchronizable).

import Foundation
import Security

public enum Keychain {
    private static let service = "com.doomcoder.app.companion.aikey"

    public static func set(_ value: String, account: String) {
        set(value, account: account, service: service)
    }

    public static func get(account: String) -> String? {
        get(account: account, service: service)
    }

    public static func delete(account: String) {
        delete(account: account, service: service)
    }

    // MARK: - Service-scoped API
    // Lets callers store unrelated secrets under their own service so they can
    // never be deleted/migrated by accident (e.g. the per-device identity).

    public static func set(_ value: String, account: String, service: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public static func get(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    public static func delete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Deletes EVERY generic-password item stored under `service` (all accounts).
    /// Used by the apps' "Erase All Data" reset so leftover keys can't survive a
    /// reinstall. No-op if nothing is stored.
    public static func deleteAll(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}
