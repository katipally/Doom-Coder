// DeviceProfile.swift — DoomCoderCore
// A persistent record describing one device that participates in DoomCoder
// connections. Stored locally on each side (Mac and iOS) in UserDefaults /
// App Group cache. Devices are never sent over the wire; only their IDs and
// human-friendly names are, embedded in records like MacStatus.

import Foundation

public struct DeviceProfile: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: DeviceID
    public var name: String
    public var kind: DeviceKind
    public var route: Route
    public var lastSeen: Date?
    public var capabilities: [String]
    public var createdAt: Date

    public init(
        id: DeviceID = DeviceIDFactory.make(),
        name: String,
        kind: DeviceKind,
        route: Route = .iCloud,
        lastSeen: Date? = nil,
        capabilities: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.route = route
        self.lastSeen = lastSeen
        self.capabilities = capabilities
        self.createdAt = createdAt
    }

    public var symbolName: String { kind.symbolName }

    public var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty
            ? kind.displayName
            : name
    }

    public var isStale: Bool {
        guard let lastSeen else { return true }
        return Date().timeIntervalSince(lastSeen) > 600
    }

    public var isFresh: Bool {
        guard let lastSeen else { return false }
        return Date().timeIntervalSince(lastSeen) < 180
    }
}
