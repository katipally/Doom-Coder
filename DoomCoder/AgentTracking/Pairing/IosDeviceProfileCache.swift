// IosDeviceProfileCache.swift — DoomCoder Mac
//
// v2.7: in-memory cache of every iOS device's profile (display name,
// model, last seen) so DeviceRow can render "Yash's iPhone" instead of
// a generic "iPhone" label. Populated by CloudKitPusher.ingestPeerStatus
// when a PeerStatus record arrives via the Mac's read-pipeline.

import Foundation
import Combine
import DoomCoderCore

@MainActor
public final class IosDeviceProfileCache: ObservableObject {
    public static let shared = IosDeviceProfileCache()

    public struct Profile: Equatable, Sendable {
        public let iosDeviceId: String
        public let name: String
        public let model: String
        public let systemName: String
        public let appVersion: String
        public let lastSeen: Date
    }

    @Published public private(set) var byId: [String: Profile] = [:]

    private init() {}

    public func upsert(_ p: Profile) {
        byId[p.iosDeviceId] = p
    }

    public func name(for iosDeviceId: String) -> String? {
        byId[iosDeviceId]?.name
    }

    /// v5.1: inserts a placeholder profile so DeviceRow has *some*
    /// name to render the moment a Connection is created (e.g. when
    /// the Mac's "Allow" sheet creates a new auto-attached row, or
    /// when the very first heart-beat triggers Part A's auto-attach
    /// path). The first real heart-beat overwrites this entry with
    /// the iOS device's user-set name (e.g. "Yash's iPhone 17 Pro
    /// Max"). If no real heart-beat ever lands, the placeholder
    /// keeps the row from rendering as a blank.
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
    }
}
