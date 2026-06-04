// ServerRecordCache.swift
//
// Canonical CKSyncEngine helper (per WWDC 2023 "Meet CKSyncEngine"): persist
// each server-known CKRecord's *system fields* (recordChangeTag, creation
// date, modification date, …) to disk so subsequent saves are treated as
// UPDATEs rather than blind INSERTs.
//
// Without this persistence, every Mac launch re-builds CKRecords from local
// data with no recordChangeTag → CloudKit returns CKError 14/2004
// ("record to insert already exists") and CKSyncEngine retries forever.
//
// We only need to persist server-side system fields for records with a
// STABLE recordID that gets re-saved across launches:
//   • SettingsRecord ("Settings-singleton") — both Mac & iOS write
//   • MacStatusRecord ("MacStatus-{macId}") — heartbeat
//
// Event / NotificationLog / Session use unique IDs per write and are pure
// inserts; they do NOT need this cache.

#if canImport(CloudKit)
import Foundation
import CloudKit

public final class ServerRecordCache {

    private let defaults: UserDefaults
    private let key: String

    /// `defaults` should be `UserDefaults.standard` on the Mac and the
    /// app-group `UserDefaults` on iOS. `key` namespaces the cache so the
    /// Mac and iOS apps don't trample each other if they ever shared a
    /// container (they don't, but it's free safety).
    public init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    /// In-memory mirror — populated lazily on first access. Keys are the
    /// CKRecord recordName so callers don't need a CKRecord.ID to look up.
    private var memory: [String: CKRecord] = [:]
    private var loaded = false

    /// Decode the on-disk dictionary into CKRecord stubs (system fields only).
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let blob = defaults.dictionary(forKey: key) as? [String: Data] else { return }
        for (name, data) in blob {
            guard let decoder = try? NSKeyedUnarchiver(forReadingFrom: data) else { continue }
            decoder.requiresSecureCoding = true
            if let rec = CKRecord(coder: decoder) {
                memory[name] = rec
            }
        }
    }

    /// Returns a CKRecord stub carrying the server's recordChangeTag, or
    /// nil if we've never seen this record. Mutate it (set per-field values)
    /// and pass to the engine — CloudKit will treat the save as UPDATE.
    public func record(forName name: String) -> CKRecord? {
        loadIfNeeded()
        return memory[name]
    }

    public func record(for id: CKRecord.ID) -> CKRecord? {
        record(forName: id.recordName)
    }

    /// Persist a server record (after a successful save or a fetch).
    public func store(_ record: CKRecord) {
        loadIfNeeded()
        memory[record.recordID.recordName] = record
        flush()
    }

    /// Remove a record (e.g. after the zone is wiped or the record deleted).
    public func remove(name: String) {
        loadIfNeeded()
        memory.removeValue(forKey: name)
        flush()
    }

    public func remove(id: CKRecord.ID) {
        remove(name: id.recordName)
    }

    /// Clear the entire cache (used by devWipeCloudKitZone + account switch).
    public func clear() {
        memory.removeAll()
        loaded = true
        defaults.removeObject(forKey: key)
    }

    /// Encode each cached CKRecord's system fields back to disk.
    private func flush() {
        var blob: [String: Data] = [:]
        for (name, rec) in memory {
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            rec.encodeSystemFields(with: coder)
            coder.finishEncoding()
            blob[name] = coder.encodedData
        }
        defaults.set(blob, forKey: key)
    }
}
#endif
