// Stores.swift — DoomCoder Companion
// Observable singleton stores that hold the decoded CloudKit state for the
// main app. MacStatusStore, SessionStore, NotificationLogStore, and
// SettingsStore are all defined here for easy cross-store access without
// creating import cycles.

import Foundation
import CloudKit
import DoomCoderCore

// MARK: - MacStatusStore

/// Holds the latest MacStatusRecord for every paired Mac.
@MainActor
@Observable
final class MacStatusStore {

    static let shared = MacStatusStore()
    private init() {
        primaryMacIdOverride = AppGroupCache.defaults.string(forKey: Self.primaryMacIdKey)
        // Warm from App Group cache so the cold-launch UI shows the last
        // known Mac instantly, before the first CloudKit fetch resolves.
        if let cached = AppGroupCache.read([String: MacStatusRecord].self,
                                           forKey: Self.cacheKey) {
            byMacId = cached
        }
    }

    /// App Group cache key for the full byMacId snapshot.
    static let cacheKey = "cache.macStatus.byMacId"

    /// UserDefaults key (App Group) that pins a specific macId as the primary.
    /// When unset, primary falls back to "most recently seen Mac".
    static let primaryMacIdKey = "doomcoder.companion.primaryMacId"

    private(set) var byMacId: [String: MacStatusRecord] = [:]
    private(set) var primaryMacIdOverride: String?

    /// User-pinned primary Mac, if set and still visible. Otherwise the most
    /// recently seen Mac (preserves the v2.x behaviour for single-Mac users).
    var primary: MacStatusRecord? {
        if let id = primaryMacIdOverride, let pinned = byMacId[id] {
            return pinned
        }
        return byMacId.values.max(by: { $0.lastSeen < $1.lastSeen })
    }

    func setPrimary(_ macId: String?) {
        primaryMacIdOverride = macId
        if let id = macId {
            AppGroupCache.defaults.set(id, forKey: Self.primaryMacIdKey)
        } else {
            AppGroupCache.defaults.removeObject(forKey: Self.primaryMacIdKey)
        }
    }

    func upsert(_ r: MacStatusRecord) {
        byMacId[r.macId] = r
        AppGroupCache.write(byMacId, forKey: Self.cacheKey)
    }

    func clear() {
        byMacId.removeAll()
        primaryMacIdOverride = nil
        AppGroupCache.defaults.removeObject(forKey: Self.primaryMacIdKey)
        AppGroupCache.defaults.removeObject(forKey: Self.cacheKey)
    }
}

// MARK: - SessionStore

/// Holds all synced SessionRecords. Live sessions are surfaced first.
@MainActor
@Observable
final class SessionStore {

    static let shared = SessionStore()
    private init() {}

    private(set) var byKey: [String: SessionRecord] = [:]

    /// Active (not yet ended / failed) sessions sorted by most recently updated.
    var live: [SessionRecord] {
        byKey.values
            .filter { !$0.hasEnded && !$0.hasFailed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func upsert(_ r: SessionRecord) {
        byKey[r.sessionKey] = r
    }

    func clear() { byKey.removeAll() }
}

// MARK: - NotificationLogStore

/// Append-only log of NotificationLogRecords, mirrored to App Group so the NSE
/// can also read recent entries without a CloudKit round-trip.
@MainActor
@Observable
final class NotificationLogStore {

    static let shared = NotificationLogStore()
    private init() {
        // Warm from the App Group cache so entries survive a cold launch.
        if let cached = AppGroupCache.read([NotificationLogRecord].self,
                                           forKey: AppGroupCache.notificationLogKey) {
            entries = cached
        }
    }

    var entries: [NotificationLogRecord] = []

    private let maxEntries = 500

    func append(_ r: NotificationLogRecord) {
        // Deduplicate by notifId.
        guard !entries.contains(where: { $0.notifId == r.notifId }) else { return }
        entries.insert(r, at: 0)                    // maintain ts-desc order
        entries.sort { $0.ts > $1.ts }
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        // Persist the trimmed list for the NSE.
        AppGroupCache.write(entries, forKey: AppGroupCache.notificationLogKey)
        // Banner display is owned exclusively by the Notification Service
        // Extension on the CloudKit push path. We do NOT post a duplicate
        // local notification from here — that path produced a second banner
        // for every event and re-introduced the "On <MacName>" subtitle.
    }
}

// MARK: - SettingsStore

/// Holds the singleton SettingsRecord. Local mutations use per-field LWW touch()
/// before being queued into CloudKit via CompanionSyncEngine.
@MainActor
@Observable
final class SettingsStore {

    static let shared = SettingsStore()

    /// Persistent server-record cache (system fields only). Without on-disk
    /// persistence of `Settings-singleton`'s recordChangeTag, every cold
    /// launch attempts a blind INSERT and CloudKit returns CKError 14/2004
    /// forever. Storage lives in the app-group defaults so the main app and
    /// any future widget extension share the same view.
    private let serverRecords = ServerRecordCache(
        defaults: AppGroupCache.defaults,
        key: "ck.ios.serverRecords"
    )

    private init() {
        // Seed deviceId once per install.
        if AppGroupCache.defaults.string(forKey: "device.id") == nil {
            AppGroupCache.defaults.set(UUID().uuidString, forKey: "device.id")
        }
    }

    private(set) var current: SettingsRecord = SettingsRecord()

    /// The raw CKRecord last fetched from the server, including its changeTag.
    /// Reads through the persistent cache so the first save after a cold
    /// launch carries the recordChangeTag → CloudKit performs UPDATE, not
    /// INSERT.
    var serverRecord: CKRecord? {
        get { serverRecords.record(forName: SettingsRecord.singletonRecordName) }
        set {
            if let v = newValue { serverRecords.store(v) }
            else { serverRecords.remove(name: SettingsRecord.singletonRecordName) }
        }
    }

    private var deviceId: String {
        AppGroupCache.defaults.string(forKey: "device.id") ?? "iOS"
    }

    /// Applies a remotely fetched record using per-field LWW merge.
    /// `rawRecord` carries the server's changeTag — store it so future saves
    /// perform an UPDATE rather than a blind INSERT.
    func applyRemote(_ remote: SettingsRecord, rawRecord: CKRecord? = nil) {
        current.merge(with: remote)
        if let raw = rawRecord { serverRecord = raw }
    }

    /// Mutates a single field, stamps its LWW timestamp, and enqueues a CloudKit save.
    func update(field: String, mutate: (inout SettingsRecord) -> Void) {
        mutate(&current)
        current.touch(field, by: deviceId)
        // The sync engine preflights Settings-singleton by ID before enqueueing
        // so cold launches and concurrent Mac edits don't save with a missing
        // or stale recordChangeTag.
        CompanionSyncEngine.shared.enqueueSettingsSave(current)
    }

    /// v3.2 — toggling per-agent overrides bumps per-(agent, sub-key) LWW
    /// timestamps so a Mac install/uninstall happening in the same window
    /// merges cleanly instead of being clobbered by the bulk JSON stamp.
    func updatePerAgent(agent: String,
                        subs: [String],
                        mutate: (inout SettingsRecord) -> Void) {
        mutate(&current)
        for sub in subs {
            current.touchPerAgent(agent, sub: sub, by: deviceId)
        }
        CompanionSyncEngine.shared.enqueueSettingsSave(current)
    }

    /// Wipe local settings + server-record cache. Called on `.switchAccounts`
    /// so a new iCloud account doesn't see the prior account's preferences.
    func clear() {
        current = SettingsRecord()
        serverRecords.clear()
    }
}
