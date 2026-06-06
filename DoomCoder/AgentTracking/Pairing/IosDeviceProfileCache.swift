// IosDeviceProfileCache.swift — DoomCoder Mac
//
// v7 revamp: the unified device store. Holds the peer iOS `DeviceRecord`s
// the Mac has read out of DoomCoderZone, keyed by `deviceId`. Replaces the
// old PeerStatus-derived `Profile` cache. Every iOS DeviceRecord the Mac
// fetches is upserted here UNCONDITIONALLY (this fixes the headline bug
// where the old code dropped the profile when no connection matched), so
// the Mac always knows the real iPhone identity.
//
// Still a `@MainActor ObservableObject` with `@Published` storage so the
// Connections UI re-renders, and still persisted to UserDefaults so cards
// render instantly on relaunch.
//
// Connection-state display is derived via
// `DerivedDeviceState.derive(hasPairing:peer:)` — see `derivedState(for:)`.

import Foundation
import Combine
import DoomCoderCore

@MainActor
public final class IosDeviceProfileCache: ObservableObject {
    public static let shared = IosDeviceProfileCache()

    /// Peer DeviceRecords (role == .ios) the Mac has read from the zone,
    /// keyed by `deviceId`.
    @Published public private(set) var byId: [String: DeviceRecord] = [:]

    private static let storageKey = "DoomCoder.DeviceRecordStore.v7"

    private init() {
        load()
    }

    // MARK: - Upsert / lookup

    /// Upsert a peer DeviceRecord. Called for every iOS DeviceRecord the Mac
    /// fetches — unconditionally, regardless of whether a Connection matches.
    public func upsert(_ record: DeviceRecord) {
        guard !record.deviceId.isEmpty else { return }
        // Merge: preserve a previously-known account identity if the incoming
        // record doesn't carry one (heartbeats may omit discoverability fields).
        var merged = record
        if merged.accountName == nil { merged.accountName = byId[record.deviceId]?.accountName }
        if merged.accountEmail == nil { merged.accountEmail = byId[record.deviceId]?.accountEmail }
        var next = byId
        next[record.deviceId] = merged
        byId = next
        save()
    }

    /// The peer DeviceRecord for a deviceId, if known.
    public func record(for deviceId: String) -> DeviceRecord? {
        byId[deviceId]
    }

    /// Display name for a deviceId (convenience for the UI).
    public func name(for deviceId: String) -> String? {
        byId[deviceId]?.displayName
    }

    /// The peer DeviceRecord for a Connection, matched by its iosDeviceId.
    public func peer(for connection: Connection) -> DeviceRecord? {
        guard !connection.iosDeviceId.isEmpty else { return nil }
        return byId[connection.iosDeviceId]
    }

    /// Derived connection state for a Connection: paired (and not removed) +
    /// the peer's DeviceRecord freshness.
    public func derivedState(for connection: Connection) -> DerivedDeviceState {
        let hasPairing = connection.removedAt == nil
        return DerivedDeviceState.derive(hasPairing: hasPairing, peer: peer(for: connection))
    }

    /// Drop a record (e.g. on hard disconnect or a fetched deletion) so stale
    /// identities don't linger.
    public func remove(deviceId: String) {
        guard byId[deviceId] != nil else { return }
        var next = byId
        next.removeValue(forKey: deviceId)
        byId = next
        save()
    }

    /// Inserts a placeholder DeviceRecord so the UI has *some* name to render
    /// the moment a Connection is created, before the first real DeviceRecord
    /// lands. Never overwrites a real record.
    public func insertPlaceholder(iosDeviceId: String, name: String) {
        guard !iosDeviceId.isEmpty, byId[iosDeviceId] == nil else { return }
        var next = byId
        next[iosDeviceId] = DeviceRecord(
            deviceId: iosDeviceId,
            role: .ios,
            displayName: name,
            model: "",
            osVersion: "",
            appVersion: "",
            lastSeen: .distantPast   // placeholder → derives as .pending, not .active
        )
        byId = next
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: DeviceRecord].self, from: data)
        else { return }
        byId = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(byId) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
