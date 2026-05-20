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
    static let defaults: UserDefaults = UserDefaults(suiteName: suiteName)!

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
}
