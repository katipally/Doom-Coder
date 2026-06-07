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
//   • ControlCommandRecord ("ControlCommand-{uuid}") — Mac ack
//
// Event / NotificationLog / Session use unique IDs per write and are pure
// inserts; they do NOT need this cache.

#if canImport(CloudKit)
import Foundation
import CloudKit

public final class ServerRecordCache: @unchecked Sendable {

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

    /// Guards every read/write of `memory`, `loaded`, and the `defaults`
    /// blob. `NSLock` is used (not an `actor`) because the public API must
    /// remain synchronous: callers (notably the CKSyncEngine delegate
    /// callbacks) hand us a `CKRecord` and expect a stub back without
    /// `await`. `CKRecord` and `NSKeyedArchiver` are not `Sendable`-safe to
    /// cross actor executors.
    private let lock = NSLock()

    /// Decode the on-disk dictionary into CKRecord stubs (system fields only).
    private func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        return memory[name]
    }

    public func record(for id: CKRecord.ID) -> CKRecord? {
        record(forName: id.recordName)
    }

    /// Persist a server record (after a successful save or a fetch).
    public func store(_ record: CKRecord) {
        loadIfNeeded()
        lock.lock()
        memory[record.recordID.recordName] = record
        // Build the disk blob while holding the lock so a concurrent
        // `clear()` cannot interleave between our memory write and our
        // disk write (which would resurrect stale data on next launch).
        // Encoding is CPU-bound (no I/O), so holding the lock is fine.
        var blob: [String: Data] = [:]
        for (n, rec) in memory {
            blob[n] = encodeRecord(rec) ?? Data()
        }
        defaults.set(blob, forKey: key)
        lock.unlock()
    }

    /// Remove a record (e.g. after the zone is wiped or the record deleted).
    public func remove(name: String) {
        loadIfNeeded()
        lock.lock()
        memory.removeValue(forKey: name)
        var blob: [String: Data] = [:]
        for (n, rec) in memory {
            blob[n] = encodeRecord(rec) ?? Data()
        }
        defaults.set(blob, forKey: key)
        lock.unlock()
    }

    public func remove(id: CKRecord.ID) {
        remove(name: id.recordName)
    }

    /// Clear the entire cache (used by devWipeCloudKitZone + account switch).
    public func clear() {
        lock.lock()
        memory.removeAll()
        loaded = true
        defaults.removeObject(forKey: key)
        lock.unlock()
    }

    /// Encode a single CKRecord's system fields. Pure CPU work with no I/O,
    /// so it is safe to call inside the critical section. Pulled out of
    /// `store`/`remove` as a helper so the encoding rule lives in one place.
    private func encodeRecord(_ record: CKRecord) -> Data? {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
}
#endif
