import Foundation

/// Duration choices for the Auto-mode snooze override. Held by both the Mac
/// panel and the iOS companion; raw values are wire-stable for CloudKit.
///
/// Snooze holds the sleep assertion for the chosen duration regardless of
/// agent or user-activity signals. It is only meaningful in Auto mode.
/// (Caffeine-style.)
public enum SnoozeDuration: String, CaseIterable, Codable, Sendable {
    case fifteenMinutes = "15m"
    case oneHour        = "1h"
    case indefinite     = "indefinite"

    /// Seconds from now until snooze expires. `nil` for `.indefinite` (no expiry).
    public var seconds: TimeInterval? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .oneHour:        return 60 * 60
        case .indefinite:     return nil
        }
    }

    public var displayName: String {
        switch self {
        case .fifteenMinutes: return "15 minutes"
        case .oneHour:        return "1 hour"
        case .indefinite:     return "Until I turn it off"
        }
    }

    /// Short label for compact UIs (status pills, Live Activities).
    public var shortLabel: String {
        switch self {
        case .fifteenMinutes: return "15m"
        case .oneHour:        return "1h"
        case .indefinite:     return "∞"
        }
    }
}
