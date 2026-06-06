// IosDeviceProfileCache.swift — DoomCoder Mac
//
// v2.7: in-memory cache of every iOS device's profile (display name,
// model, last seen) so DeviceRow can render "Yash's iPhone" instead of
// a generic "iPhone" label. Populated by CloudKitPusher.ingestPeerStatus
// when a PeerStatus record arrives via the Mac's read-pipeline.
//
// v6: persisted to UserDefaults so the card renders name/model/OS
// instantly on relaunch (previously in-memory only → blank cards until
// the next heartbeat landed). Also carries the peer's iCloud identity
// (account name/email from CloudKit discoverability).

import Foundation
import Combine
import DoomCoderCore

@MainActor
public final class IosDeviceProfileCache: ObservableObject {
    public static let shared = IosDeviceProfileCache()

    public struct Profile: Equatable, Sendable, Codable {
        public let iosDeviceId: String
        public let name: String
        public let model: String
        public let systemName: String
        public let appVersion: String
        public let lastSeen: Date
        /// v6: best-effort iCloud identity of the iPhone's account.
        public var accountName: String?
        public var accountEmail: String?

        public init(iosDeviceId: String, name: String, model: String,
                    systemName: String, appVersion: String, lastSeen: Date,
                    accountName: String? = nil, accountEmail: String? = nil) {
            self.iosDeviceId = iosDeviceId
            self.name = name
            self.model = model
            self.systemName = systemName
            self.appVersion = appVersion
            self.lastSeen = lastSeen
            self.accountName = accountName
            self.accountEmail = accountEmail
        }
    }

    @Published public private(set) var byId: [String: Profile] = [:]

    private static let storageKey = "DoomCoder.IosDeviceProfileCache.v6"

    private init() {
        load()
    }

    public func upsert(_ p: Profile) {
        // Preserve a previously-known identity if the incoming profile
        // doesn't carry one (heartbeats may omit the discoverability fields).
        var merged = p
        if merged.accountName == nil { merged.accountName = byId[p.iosDeviceId]?.accountName }
        if merged.accountEmail == nil { merged.accountEmail = byId[p.iosDeviceId]?.accountEmail }
        byId[p.iosDeviceId] = merged
        save()
    }

    public func name(for iosDeviceId: String) -> String? {
        byId[iosDeviceId]?.name
    }

    public func profile(for iosDeviceId: String) -> Profile? {
        byId[iosDeviceId]
    }

    /// Drop a profile (e.g. on hard disconnect) so stale identities don't linger.
    public func remove(iosDeviceId: String) {
        byId.removeValue(forKey: iosDeviceId)
        save()
    }

    /// v5.1: inserts a placeholder profile so DeviceRow has *some*
    /// name to render the moment a Connection is created. The first
    /// real heart-beat overwrites this entry with the iOS device's
    /// user-set name. If no real heart-beat ever lands, the
    /// placeholder keeps the row from rendering as a blank.
    public func insertPlaceholder(iosDeviceId: String, name: String) {
        // Don't overwrite a real profile with a placeholder.
        if byId[iosDeviceId] != nil { return }
        byId[iosDeviceId] = Profile(
            iosDeviceId: iosDeviceId,
            name: name,
            model: "",
            systemName: "",
            appVersion: "",
            lastSeen: Date()
        )
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: Profile].self, from: data)
        else { return }
        byId = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(byId) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
