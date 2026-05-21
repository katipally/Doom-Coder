// Stores.swift — DoomCoder Companion
// Observable singleton stores that hold the decoded CloudKit state for the
// main app. MacStatusStore, SessionStore, NotificationLogStore, SettingsStore,
// and WoLStore are all defined here for easy cross-store access without
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
    private init() {}

    private(set) var byMacId: [String: MacStatusRecord] = [:]

    /// Most recently seen Mac (used as the "primary" Mac for single-Mac flows).
    var primary: MacStatusRecord? {
        byMacId.values.max(by: { $0.lastSeen < $1.lastSeen })
    }

    func upsert(_ r: MacStatusRecord) {
        byMacId[r.macId] = r
    }

    func clear() { byMacId.removeAll() }
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
    private init() {
        // Seed deviceId once per install.
        if AppGroupCache.defaults.string(forKey: "device.id") == nil {
            AppGroupCache.defaults.set(UUID().uuidString, forKey: "device.id")
        }
    }

    private(set) var current: SettingsRecord = SettingsRecord()

    /// The raw CKRecord last fetched from the server, including its changeTag.
    /// MUST be reused when saving so CloudKit performs an UPDATE (not INSERT).
    var serverRecord: CKRecord?

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
        // Patch the server record (preserves changeTag → UPDATE, not INSERT).
        // Falls back to creating a new record only if the server record has
        // never been fetched (unlikely in practice after first sync).
        CompanionSyncEngine.shared.enqueueSave(current.toCKRecord(base: serverRecord))
    }
}

// MARK: - WoLStore

/// Caches WoLProfileRecords keyed by macId for Wake-on-LAN support.
@MainActor
@Observable
final class WoLStore {

    static let shared = WoLStore()
    private init() {}

    private(set) var byMacId: [String: WoLProfileRecord] = [:]

    func upsert(_ r: WoLProfileRecord) {
        byMacId[r.macId] = r
    }

    /// Profile for the primary Mac (mirrors MacStatusStore.primary selection).
    var primary: WoLProfileRecord? {
        guard let id = MacStatusStore.shared.primary?.macId else { return nil }
        return byMacId[id]
    }
}
