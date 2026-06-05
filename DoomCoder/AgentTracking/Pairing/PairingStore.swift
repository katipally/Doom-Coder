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
        // v2.9: one-shot migrations —
        //   (a) macDeviceId was DeviceIDFactory.make() (22-char base64url, random
        //       per launch) → replace with the stable IOPlatformUUID-based macId.
        //   (b) implicit connection id was "implicit-<macId>" (per-Mac) →
        //       "implicit-<macId>-<iosDeviceId>" (per Mac+iOS pair).
        // v2.9+: remove phantom implicit connections (no ckShareRef = auto-created).
        // Only explicitly-paired CKShare connections are kept.
        let beforeCount = loaded.count
        loaded = loaded.filter { $0.ckShareRef != nil }
        let needsSave = loaded.count != beforeCount
        self.connections = loaded
        if needsSave { Self.saveConnectionsInternal(loaded, to: defaults, key: connectionsKey) }
    }

    // MARK: - Connections

    public func upsert(_ connection: Connection) {
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx] = connection
        } else {
            connections.append(connection)
        }
        saveConnections()
        connectionsDidChange.send(connections)
        pruneStale()
    }

    public func remove(connectionId: String) {
        connections.removeAll { $0.id == connectionId }
        saveConnections()
        connectionsDidChange.send(connections)
    }

    public func connection(forIosDeviceId iosId: DeviceID) -> Connection? {
        connections.first { $0.iosDeviceId == iosId }
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
        let before = connections.count
        connections.removeAll { conn in
            guard conn.status == .suspended else { return false }
            guard let lastSync = conn.lastSyncAt else { return false }
            return lastSync < cutoff
        }
        if connections.count != before {
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
