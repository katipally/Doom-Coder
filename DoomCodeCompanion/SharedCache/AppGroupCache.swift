// AppGroupCache.swift — DoomCode Companion
// Shared storage layer accessible by both the main app and the Notification
// Service Extension via the App Group container. Provides typed JSON helpers
// and a file-system URL for binary blobs (agent icons).

import Foundation
import DoomCodeCore

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

    /// Deletes the entire cached-icon directory (Data & Privacy → clear cached
    /// agent data). Icons re-download for any still-paired Mac.
    static func clearIcons() {
        guard let dir = iconsDir else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Full erase (Data & Privacy → Erase All Data)

    /// Removes ALL App Group state: every UserDefaults key in the suite plus all
    /// files in the shared container (SQLite mirror, icons, etc.). Local-only —
    /// iCloud records are untouched. Call this right before quitting the app.
    static func eraseEverything() {
        defaults.removePersistentDomain(forName: suiteName)
        if let dir = containerURL,
           let items = try? FileManager.default.contentsOfDirectory(
               at: dir, includingPropertiesForKeys: nil) {
            for url in items { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - NotificationLog mirror key

    static let notificationLogKey = "cache.notificationLog"
    static let installedAgentsKey  = "cache.installedAgents"

    // MARK: - Device name
    //
    // The user-typed custom device name. Stored in the App Group so the NSE can
    // read it too. Empty = "use the marketing model name" (DeviceModelName).
    private static let customDeviceNameKey = "doomcoder.companion.customDeviceName"

    /// User-typed custom device name ("" when unset). Trimmed on write.
    static var customDeviceName: String {
        get { defaults.string(forKey: customDeviceNameKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed, forKey: customDeviceNameKey)
        }
    }

    /// The name this device publishes/shows: the custom name if set, else the
    /// marketing model name (e.g. "iPhone 17 Pro").
    static var resolvedDeviceName: String {
        let custom = customDeviceName
        return custom.isEmpty ? DeviceModelName.current : custom
    }

    // MARK: - Schema version guard
    //
    // Bumped whenever a cache key's encoded shape changes incompatibly. On
    // mismatch we nuke the affected keys so a stale decode doesn't silently
    // return nil for the rest of the app's lifetime.
    private static let schemaVersionKey = "cache.schemaVersion"
    // v3: shared-zone + CKShare model. The CloudKit zone moved from the single
    // private-DB "DoomCoderZone" to a per-Mac shared zone, so ALL cached sync
    // state (engine token, server records, learned zones, Mac cache) is stale and
    // must be wiped — the user re-pairs once via QR/link (the "Reconnect" flow).
    private static let currentSchemaVersion = 3

    /// Call once on app launch (after `runV3MigrationOnce`). Idempotent.
    /// Wipes caches that are incompatible with the current schema version.
    static func enforceSchemaVersion() {
        let stored = defaults.integer(forKey: schemaVersionKey)
        guard stored < currentSchemaVersion else { return }
        let staleKeys = [
            "cache.macStatus.byMacId",
            notificationLogKey,
            "doomcoder.companion.pairedMacEverSeen",
            // v3 shared-zone migration — drop all old private-DB sync state.
            "ck.engineState",
            "ck.ios.serverRecords",
            "ck.ios.macZones.v1",
            "ck.ios.environment.v1",
            "ck.ios.environment.v2",
            "doomcoder.companion.primaryMacId"
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
