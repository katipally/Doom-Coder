// ConnectionStore.swift — DoomCoder Companion
// Local persistence + observable store for the iOS side's Connection list.
// The Connection list is what the UI uses to decide which Macs to render
// and (in future) which Macs to filter pushes to. In v2.7 there is no
// per-device filter, so this store is just metadata.

import Foundation
import Combine
import DoomCoderCore

@MainActor
@Observable
final class ConnectionStore {

    static let shared = ConnectionStore()

    static let cacheKey = "cache.connections.v1"

    private(set) var connections: [Connection] = []

    private init() {
        if let cached = AppGroupCache.read([Connection].self, forKey: Self.cacheKey) {
            connections = Self.migrateV5(cached)
        }
        Task {
            let fetched = await LocalStore.shared.fetchConnections()
            let migrated = Self.migrateV5(fetched)
            connections = migrated
            AppGroupCache.write(migrated, forKey: Self.cacheKey)
            if !migrated.isEmpty {
                NotificationCenter.default.post(
                    name: .connectionsChanged, object: nil
                )
            }
        }
    }

    /// v5 migration: same-account (.iCloud route) Connections are now
    /// first-class. v2.9 used to delete them on every launch as
    /// "phantoms" because the iOS app was supposed to be read-only
    /// with no QR required. With the v5 auto-attach path (see
    /// `AutoPairDiscovery`) these rows are real user data and must
    /// survive a relaunch. The v2.9 phantom-delete ran on every
    /// launch and wiped them — turning into the "Mac shows connected
    /// but iPhone doesn't" bug users reported.
    private static func migrateV5(_ list: [Connection]) -> [Connection] {
        let defaults = AppGroupCache.defaults
        let flag = "doomcoder.connectionsStore.v5.disablePhantomDelete"
        if !defaults.bool(forKey: flag) {
            // One-shot: write a v5 tombstone-counter so the legacy
            // phantom-delete code path is permanently off. Existing
            // phantoms are upgraded in place — they were correctly
            // auto-attached Connections; the v2.9 deletion logic
            // was a bug.
            for c in list where c.stateChangeCounter == 0 {
                var updated = c
                updated.stateChangeCounter = 1
                LocalStore.shared.upsertConnection(updated)
            }
            defaults.set(true, forKey: flag)
        }
        return list
    }

    var active: [Connection] { connections.filter { $0.status == .active } }

    var primary: Connection? {
        active.max(by: { ($0.lastSyncAt ?? .distantPast) < ($1.lastSyncAt ?? .distantPast) })
    }

    /// v5.3: ATOMIC assignment. The old in-place
    /// `connections[idx] = c` / `connections.append(c)` /
    /// `connections.removeAll { ... }` patterns can fire while
    /// SwiftUI is mid-render — `ForEach` diffs against the
    /// previous array reference, sees a count mismatch on a
    /// single element being mutated, and crashes the
    /// UICollectionView with "Invalid update: invalid number
    /// of items in section 1". Reassigning the whole
    /// `[Connection]` value with `=` gives the @Observable
    /// runtime one consistent snapshot to diff against.
    func upsert(_ c: Connection) {
        let wasEmpty = active.isEmpty
        if let idx = connections.firstIndex(where: { $0.id == c.id }) {
            let existing = connections[idx]
            if c.stateChangeCounter < existing.stateChangeCounter {
                return
            }
            var next = connections
            next[idx] = c
            connections = next
        } else {
            connections = connections + [c]
        }
        AppGroupCache.write(connections, forKey: Self.cacheKey)
        LocalStore.shared.upsertConnection(c)
        pruneStale()
        // v2.7: a brand-new active connection is the trigger for the
        // sync engine to start (re)attaching. Posting on every upsert is
        // safe — the engine guards against re-entry.
        if !wasEmpty || c.status == .active {
            NotificationCenter.default.post(name: .connectionsChanged, object: nil)
        }
    }

    /// Find an existing Connection by its macId, regardless of
    /// iosDeviceId. Used by `AutoPairDiscovery` to detect "we have
    /// a row for this Mac but with an old iosDeviceId — the user
    /// reinstalled the iOS app" and trigger the reinstall-detected
    /// CSC fast path. Returns the row + the matched iosDeviceId
    /// so the caller can tell whether it's a clean hit or a
    /// mismatch.
    func findByMacId(_ macId: String) -> (connection: Connection, matchedIosId: String)? {
        guard let conn = connections.first(where: { $0.macDeviceId == macId }) else {
            return nil
        }
        return (conn, conn.iosDeviceId)
    }

    /// v5: force the local row to adopt a new iosDeviceId (e.g.
    /// when the iCloud Keychain restored a different id than the
    /// Mac's Connection has). Increments stateChangeCounter and
    /// sets pairingOrigin to `.reinstall`.
    func reattachWithNewIosId(connectionId: String, newIosDeviceId: String) {
        guard let idx = connections.firstIndex(where: { $0.id == connectionId }) else { return }
        var c = connections[idx]
        c.iosDeviceId = newIosDeviceId
        c.pairingOrigin = .reinstall
        c.stateChangeCounter += 1
        c.removedAt = nil
        c.status = .active
        c.lastSyncAt = Date()
        var next = connections
        next[idx] = c
        connections = next
        AppGroupCache.write(connections, forKey: Self.cacheKey)
        LocalStore.shared.upsertConnection(c)
        NotificationCenter.default.post(name: .connectionsChanged, object: nil)
    }

    /// v5.3: hard-delete. The old tombstone-on-remove behaviour
    /// caused the "row resurrects on refresh / swipe to delete
    /// leaves a 'Removed 40s ago' pill forever" bug. The user's
    /// mental model for "Disconnect" is "this Mac is gone from
    /// my list" — not "this Mac is hidden for 30 days, then
    /// purges". Re-pairing creates a fresh Connection with the
    /// same implicit id, so the row is reborn with fresh
    /// metadata either way.
    func remove(id: String) {
        let next = connections.filter { $0.id != id }
        guard next.count != connections.count else { return }
        connections = next
        AppGroupCache.write(connections, forKey: Self.cacheKey)
        LocalStore.shared.deleteConnection(id: id)
        NotificationCenter.default.post(name: .connectionsChanged, object: nil)
    }

    /// v2.8: GC pass. Removes connections that have been .suspended
    /// for longer than the staleness threshold. The 1-hour cutoff
    /// matches the dashboard's "stale (>10 min)" indicator with
    /// enough headroom that a temporarily-offline iPhone (e.g.,
    /// airplane mode for a flight) doesn't get pruned prematurely.
    private func pruneStale(olderThan: TimeInterval = 3600) {
        let cutoff = Date().addingTimeInterval(-olderThan)
        let next = connections.filter { conn in
            guard conn.status == .suspended else { return true }
            guard let lastSync = conn.lastSyncAt else { return true }
            return lastSync >= cutoff
        }
        if next.count != connections.count {
            connections = next
            AppGroupCache.write(connections, forKey: Self.cacheKey)
        }
    }

    /// Helper for callers that need to hard-delete a tombstone
    /// (e.g. user explicitly chose "Forget" instead of waiting
    /// 30 days for the natural purge).
    func hardRemove(id: String) {
        let next = connections.filter { $0.id != id }
        guard next.count != connections.count else { return }
        connections = next
        AppGroupCache.write(connections, forKey: Self.cacheKey)
        LocalStore.shared.deleteConnection(id: id)
        NotificationCenter.default.post(name: .connectionsChanged, object: nil)
    }

    /// True if the connection's status is anything other than .active.
    /// Used by the row to pick the right tint on the status pill and
    /// by the dashboard's stale-affordance banner.
    var hasInactiveConnection: Bool {
        connections.contains { $0.status != .active && $0.status != .pending }
    }

    /// Returns the connections the user has explicitly removed.
    /// The UI shows a "Re-pair" banner for the most recent one.
    var mostRecentTombstoned: Connection? {
        connections
            .filter { $0.status == .removed }
            .max(by: { ($0.removedAt ?? .distantPast) < ($1.removedAt ?? .distantPast) })
    }

    func clear() {
        connections = []
        AppGroupCache.defaults.removeObject(forKey: Self.cacheKey)
        NotificationCenter.default.post(name: .connectionsChanged, object: nil)
    }
}

extension Notification.Name {
    /// Posted whenever the set of active Connections changes (add / remove /
    /// status change). The sync engine listens to this to (re)attach or
    /// tear down, so an empty Connection list keeps the engine offline.
    static let connectionsChanged = Notification.Name("com.doomcoder.connectionsChanged")
    /// v5.1: posted when a Mac denies a CSC{pending,origin:ios} pair
    /// request from the "Same iCloud" discoverable list. The
    /// SameIcloudTab observes this and dismisses its pair sheet
    /// with an inline error message.
    static let connectionPairDenied = Notification.Name("com.doomcoder.connectionPairDenied")
    /// v5.1: posted when a Mac accepts the same-iCloud pair
    /// request. SameIcloudTab dismisses its pair sheet and the
    /// AddMacView's onChange(of:coordinator.phase) closes the
    /// outer sheet with the success celebration.
    static let connectionPairAccepted = Notification.Name("com.doomcoder.connectionPairAccepted")
}
