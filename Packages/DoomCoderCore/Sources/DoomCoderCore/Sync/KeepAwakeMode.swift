import Foundation

/// User-selected keep-awake intent, shared by the Mac (SleepManager) and the
/// iOS companion (remote control). Raw values are the wire format used in
/// `MacStatusRecord.keepAwakeMode` and `ControlCommandRecord` payloads.
public enum KeepAwakeMode: String, Sendable, Codable, CaseIterable {
    /// Never keep the Mac awake.
    case off
    /// Always keep the Mac awake until the user (or the auto-off timer) stops it.
    case on
    /// Keep awake only while a tracked agent is in a live/working state.
    case auto

    public var displayName: String {
        switch self {
        case .off:  return "Off"
        case .on:   return "On"
        case .auto: return "Auto"
        }
    }

    /// SF Symbol shared by the Mac panel and the iOS remote card.
    public var symbol: String {
        switch self {
        case .off:  return "powersleep"
        case .on:   return "cup.and.saucer.fill"
        case .auto: return "sparkles"
        }
    }
}

/// Screen behaviour while keep-awake is active. Raw values match the legacy
/// `DoomCoderMode` strings already persisted in UserDefaults and published in
/// `MacStatusRecord.mode`.
public enum ScreenMode: String, Sendable, Codable, CaseIterable {
    /// Keep the display on (prevent display idle sleep).
    case screenOn
    /// Allow the display to sleep while the system stays awake.
    case screenOff

    public var displayName: String {
        switch self {
        case .screenOn:  return "Keep screen on"
        case .screenOff: return "Allow screen off"
        }
    }

    /// SF Symbol shared by the Mac panel and the iOS remote card.
    public var symbol: String {
        switch self {
        case .screenOn:  return "sun.max.fill"
        case .screenOff: return "moon.fill"
        }
    }
}
