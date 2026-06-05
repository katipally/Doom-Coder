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
            connections = Self.migrateV29(cached)
        }
        Task {
            let fetched = await LocalStore.shared.fetchConnections()
            let migrated = Self.migrateV29(fetched)
            connections = migrated
            AppGroupCache.write(migrated, forKey: Self.cacheKey)
            if !migrated.isEmpty {
                NotificationCenter.default.post(
                    name: .connectionsChanged, object: nil
                )
            }
        }
    }

    /// Migration: removes phantom auto-created implicit connections (those
    /// without a ckShareRef) so only explicitly-paired CKShare connections remain.
    /// Connections require explicit QR pairing — no automatic same-account wiring.
    private static func migrateV29(_ list: [Connection]) -> [Connection] {
        let phantoms = list.filter { $0.ckShareRef == nil }
        let kept = list.filter { $0.ckShareRef != nil }
        for phantom in phantoms {
            LocalStore.shared.deleteConnection(id: phantom.id)
        }
        return kept
    }

    var active: [Connection] { connections.filter { $0.status == .active } }

    var primary: Connection? {
        active.max(by: { ($0.lastSyncAt ?? .distantPast) < ($1.lastSyncAt ?? .distantPast) })
    }

    func upsert(_ c: Connection) {
        let wasEmpty = active.isEmpty
        if let idx = connections.firstIndex(where: { $0.id == c.id }) {
            connections[idx] = c
        } else {
            connections.append(c)
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

    func remove(id: String) {
        connections.removeAll { $0.id == id }
        AppGroupCache.write(connections, forKey: Self.cacheKey)
        LocalStore.shared.deleteConnection(id: id)
        // v2.7: removing the last active connection should tear down
        // the engine so the Dashboard stops showing the disconnected
        // Mac's agents.
        if active.isEmpty {
            NotificationCenter.default.post(name: .connectionsChanged, object: nil)
        }
    }

    /// v2.8: GC pass. Removes connections that have been .suspended
    /// for longer than the staleness threshold. The 1-hour cutoff
    /// matches the dashboard's "stale (>10 min)" indicator with
    /// enough headroom that a temporarily-offline iPhone (e.g.,
    /// airplane mode for a flight) doesn't get pruned prematurely.
    private func pruneStale(olderThan: TimeInterval = 3600) {
        let cutoff = Date().addingTimeInterval(-olderThan)
        let before = connections.count
        connections.removeAll { conn in
            guard conn.status == .suspended else { return false }
            guard let lastSync = conn.lastSyncAt else { return false }
            return lastSync < cutoff
        }
        if connections.count != before {
            AppGroupCache.write(connections, forKey: Self.cacheKey)
        }
    }

    func clear() {
        connections.removeAll()
        AppGroupCache.defaults.removeObject(forKey: Self.cacheKey)
        NotificationCenter.default.post(name: .connectionsChanged, object: nil)
    }
}

extension Notification.Name {
    /// Posted whenever the set of active Connections changes (add / remove /
    /// status change). The sync engine listens to this to (re)attach or
    /// tear down, so an empty Connection list keeps the engine offline.
    static let connectionsChanged = Notification.Name("com.doomcoder.connectionsChanged")
}
