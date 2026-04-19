import Foundation
import Security

// Generates and stores a random per-install ntfy topic in UserDefaults.
// Topic shape: `dc-<12 hex chars>` → shareable URL https://ntfy.sh/<topic>
//
// The topic isn't a credential — it's a randomised pub-sub address. Storing
// it in Keychain added complexity (sync prompts, entitlement friction) with
// no real security benefit, so we use UserDefaults and migrate any existing
// keychain value on first launch.
enum NtfyTopic {
    private static let topicKey = "doomcoder.ntfy.topic"
    private static let serverKey = "doomcoder.ntfy.server"
    private static let migratedKey = "doomcoder.ntfy.keychainMigrated.v1"

    // Legacy keychain coordinates (kept for one-time migration only).
    private static let legacyService = "com.doomcoder.ntfy"
    private static let legacyAccount = "topic"

    static func getOrCreate() -> String {
        migrateFromKeychainIfNeeded()
        if let existing = UserDefaults.standard.string(forKey: topicKey),
           !existing.isEmpty { return existing }
        let t = newTopic()
        UserDefaults.standard.set(t, forKey: topicKey)
        return t
    }

    @discardableResult
    static func regenerate() -> String {
        let t = newTopic()
        UserDefaults.standard.set(t, forKey: topicKey)
        return t
    }

    static var shareURL: URL? {
        URL(string: "\(server ?? "https://ntfy.sh")/\(getOrCreate())")
    }

    static var current: String? {
        migrateFromKeychainIfNeeded()
        return UserDefaults.standard.string(forKey: topicKey)
    }

    static var server: String? {
        get { UserDefaults.standard.string(forKey: serverKey) }
        set { UserDefaults.standard.set(newValue, forKey: serverKey) }
    }

    // MARK: - Migration

    /// Idempotent: runs once per install. Copies any existing keychain topic
    /// into UserDefaults, then deletes the keychain item.
    static func migrateFromKeychainIfNeeded() {
        if UserDefaults.standard.bool(forKey: migratedKey) { return }
        defer { UserDefaults.standard.set(true, forKey: migratedKey) }

        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let s = String(data: data, encoding: .utf8),
           !s.isEmpty,
           (UserDefaults.standard.string(forKey: topicKey) ?? "").isEmpty {
            UserDefaults.standard.set(s, forKey: topicKey)
        }
        // Delete legacy item regardless of whether we migrated, so we don't
        // leave behind stale keychain entries.
        let deleteQ: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount
        ]
        SecItemDelete(deleteQ as CFDictionary)
    }

    // MARK: - Internals

    private static func newTopic() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "dc-\(hex)"
    }
}
