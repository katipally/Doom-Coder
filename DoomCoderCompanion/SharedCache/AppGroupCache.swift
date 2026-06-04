// AppGroupCache.swift — DoomCoder Companion
// Shared storage layer accessible by both the main app and the Notification
// Service Extension via the App Group container. Provides typed JSON helpers
// and a file-system URL for binary blobs (agent icons).

import Foundation
import DoomCoderCore

enum AppGroupCache {

    static let suiteName = CloudKitConstants.appGroupIdentifier

    // Force-unwrapped: the app group is declared in entitlements; if this fails
    // the build configuration is broken and we want a loud crash.
    nonisolated(unsafe) static let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!

    /// Shared container URL (nil only if the App Group entitlement is missing).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }

    // MARK: - Codable JSON helpers

    static func write<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    static func read<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Icon file cache

    private static var iconsDir: URL? {
        containerURL?.appendingPathComponent("icons", isDirectory: true)
    }

    /// Writes raw PNG data to `<containerURL>/icons/<slug>.png`.
    /// Returns the written URL, or nil on failure.
    @discardableResult
    static func writeIcon(slug: String, data: Data) -> URL? {
        guard let dir = iconsDir else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(slug).png")
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Returns the URL for a cached icon, or nil if not yet downloaded.
    static func iconURL(slug: String) -> URL? {
        guard let dir = iconsDir else { return nil }
        let url = dir.appendingPathComponent("\(slug).png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - NotificationLog mirror key

    static let notificationLogKey = "cache.notificationLog"
    static let installedAgentsKey  = "cache.installedAgents"

    // MARK: - Schema version guard
    //
    // Bumped whenever a cache key's encoded shape changes incompatibly. On
    // mismatch we nuke the affected keys so a stale decode doesn't silently
    // return nil for the rest of the app's lifetime.
    private static let schemaVersionKey = "cache.schemaVersion"
    private static let currentSchemaVersion = 2

    /// Call once on app launch (after `runV3MigrationOnce`). Idempotent.
    /// Wipes notification-log / paired-mac caches if the stored schema
    /// version is older than `currentSchemaVersion`.
    static func enforceSchemaVersion() {
        let stored = defaults.integer(forKey: schemaVersionKey)
        guard stored < currentSchemaVersion else { return }
        let staleKeys = [
            notificationLogKey,
            "doomcoder.companion.pairedMacEverSeen"
        ]
        for k in staleKeys { defaults.removeObject(forKey: k) }
        defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
    }

    // MARK: - v3 first-launch migration
    //
    // Idempotent cleanup for users upgrading from 1.x → 3.0.
    // Removes App Group state that is no longer used:
    //   - cache.primaryMacName    (subtitle source — feature removed)
    //   - localPosted.*           (LocalNotificationPoster dedup keys — path removed)
    //   - nse_debug.json          (NSE payload dump — DEBUG-only now)
    // The flag `migration.v3.done` makes this a one-shot.
    private static let v3MigrationFlagKey = "migration.v3.done"

    /// Runs once per install. Subsequent launches are no-ops.
    static func runV3MigrationOnce() {
        guard defaults.bool(forKey: v3MigrationFlagKey) == false else { return }

        defaults.removeObject(forKey: "cache.primaryMacName")

        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("localPosted.") {
            defaults.removeObject(forKey: key)
        }

        if let dir = containerURL {
            let dumpURL = dir.appendingPathComponent("nse_debug.json")
            try? FileManager.default.removeItem(at: dumpURL)
        }

        defaults.set(true, forKey: v3MigrationFlagKey)
    }
}
