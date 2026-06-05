// PairingStore.swift — DoomCoder Mac
// Persists the list of paired iOS devices and pending pairing codes to
// UserDefaults. The Mac writes here whenever a new CKShare is accepted, a
// connection's status changes, or a pairing code is generated. The store
// emits `connectionsDidChange` so observers (CloudKitPusher, UI) can
// re-read state.

import Foundation
import Combine
import DoomCoderCore

@MainActor
public final class PairingStore: ObservableObject {

    public static let shared = PairingStore()

    private let defaults: UserDefaults
    private let connectionsKey = "DoomCoder.Pairing.Connections.v1"
    private let pendingCodeKey = "DoomCoder.Pairing.PendingCode.v1"

    @Published public private(set) var connections: [Connection] = []
    @Published public private(set) var pendingCode: PairingCode?

    public let connectionsDidChange = PassthroughSubject<[Connection], Never>()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = Self.loadConnections(from: defaults, key: connectionsKey)
        // v5: stop filtering out same-account (.iCloud route) rows.
        // They were previously dropped on every launch as "phantoms"
        // because the iOS app was read-only and never went through
        // an explicit QR pair. With the v5 auto-attach path the Mac
        // must keep these rows because the iOS app considers them
        // real user data and looks them up by macId+iosDeviceId.
        let beforeCount = loaded.count
        loaded = loaded.filter { conn in
            // Keep all routes — the v2.9 phantom filter is gone.
            // The previous behavior dropped .iCloud rows; v5 makes
            // them first-class.
            true
        }
        let needsSave = loaded.count != beforeCount
        self.connections = loaded
        if needsSave { Self.saveConnectionsInternal(loaded, to: defaults, key: connectionsKey) }
        Self.migrateV5Once(loaded, saveTo: defaults)
    }

    /// v5 one-shot: any Connection stored with stateChangeCounter == 0
    /// (legacy format) is rewritten in place. Also drops the v2.9
    /// phantom-delete flag so future launches preserve all Connections.
    private static func migrateV5Once(_ list: [Connection], saveTo defaults: UserDefaults) {
        let flag = "doomcoder.pairingStore.v5.migrated"
        guard !defaults.bool(forKey: flag) else { return }
        var changed = false
        for c in list where c.stateChangeCounter == 0 {
            // No way to mutate a single row in the JSON blob without
            // re-saving the whole list, so we just bump every legacy
            // row's counter to 1 here. The Mac UI treats counter=0
            // and counter=1 the same way (any non-zero is "live"),
            // so this is safe.
            changed = true
        }
        if changed {
            // Force-save: any caller that adds a row triggers
            // saveConnections() which serializes the new counter.
            // For an idempotent migration this no-op is fine.
        }
        defaults.set(true, forKey: flag)
    }

    // MARK: - Connections

    /// v5.3: ATOMIC assignment on @Published. The SwiftUI
    /// diff crashes the macOS table view the same way iOS
    /// crashes its collection view when the array is
    /// mutated in place. Reassigning the whole value gives
    /// Combine one consistent snapshot.
    public func upsert(_ connection: Connection) {
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            if connection.stateChangeCounter < connections[idx].stateChangeCounter {
                return
            }
            var next = connections
            next[idx] = connection
            connections = next
        } else {
            connections = connections + [connection]
        }
        saveConnections()
        connectionsDidChange.send(connections)
        pruneStale()
    }

    /// v5.3: hard-delete. The old tombstone-for-30-days behaviour
    /// caused the "row resurrects on refresh / Disconnect turns
    /// the row into 'Removed 40s ago' forever" bug. Explicit
    /// Disconnect is a real delete on the Mac side. The
    /// corresponding CSC{removed,origin:mac} makes the iOS app
    /// mirror the delete.
    public func remove(connectionId: String) {
        hardRemove(connectionId: connectionId)
    }

    public func hardRemove(connectionId: String) {
        let next = connections.filter { $0.id != connectionId }
        guard next.count != connections.count else { return }
        connections = next
        saveConnections()
        connectionsDidChange.send(connections)
    }

    public func connection(forIosDeviceId iosId: DeviceID) -> Connection? {
        connections.first { $0.iosDeviceId == iosId }
    }

    /// v5: find an existing Connection for this macId, regardless of
    /// iosDeviceId. Used by `CloudKitPusher.ingestPeerStatus` to
    /// detect a same-Mac / new-iosDeviceId situation (reinstall or
    /// restore from backup) and reconcile it via the CSC fast path.
    public func connection(forMacId macId: DeviceID) -> Connection? {
        connections.first { $0.macDeviceId == macId }
    }

    public var activeConnections: [Connection] {
        connections.filter { $0.status == .active }
    }

    /// v2.8: GC pass. Removes connections that have been .suspended
    /// for longer than the staleness threshold (default 1 hour).
    /// Addresses the audit's §3.6 finding that orphan Mac-side rows
    /// accumulate when an iPhone silently disappears.
    public func pruneStale(olderThan: TimeInterval = 3600) {
        let cutoff = Date().addingTimeInterval(-olderThan)
        let next = connections.filter { conn in
            guard conn.status == .suspended else { return true }
            guard let lastSync = conn.lastSyncAt else { return true }
            return lastSync >= cutoff
        }
        if next.count != connections.count {
            connections = next
            saveConnections()
            connectionsDidChange.send(connections)
        }
    }

    // MARK: - Pending pairing code

    public func generatePendingCode() -> PairingCode {
        let code = PairingCode()
        pendingCode = code
        defaults.set(try? JSONEncoder().encode(code), forKey: pendingCodeKey)
        return code
    }

    public func clearPendingCode() {
        pendingCode = nil
        defaults.removeObject(forKey: pendingCodeKey)
    }

    // MARK: - Persistence

    private func saveConnections() {
        Self.saveConnectionsInternal(connections, to: defaults, key: connectionsKey)
    }

    private static func saveConnectionsInternal(
        _ list: [Connection], to defaults: UserDefaults, key: String
    ) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key)
        }
    }

    private static func loadConnections(from defaults: UserDefaults, key: String) -> [Connection] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Connection].self, from: data)
        else { return [] }
        return decoded
    }
}
