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
}
