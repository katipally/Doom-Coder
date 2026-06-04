// DeviceKind.swift — DoomCoderCore
// Identifies a kind of device participating in a DoomCoder connection.
// Used by `DeviceProfile.kind` and the UI to pick the right SF Symbol and label.

import Foundation

public enum DeviceKind: String, Codable, Sendable, CaseIterable, Hashable {
    case mac
    case iphone
    case ipad

    public var displayName: String {
        switch self {
        case .mac:    return "Mac"
        case .iphone: return "iPhone"
        case .ipad:   return "iPad"
        }
    }

    /// SF Symbol name for use in SwiftUI. Kept here so core stays UI-agnostic
    /// (SwiftUI Image(systemName:) is the consumer).
    public var symbolName: String {
        switch self {
        case .mac:    return "macbook"
        case .iphone: return "iphone.gen3"
        case .ipad:   return "ipad"
        }
    }
}
