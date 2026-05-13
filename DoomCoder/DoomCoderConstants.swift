import Foundation

enum DoomCoderConstants {
    static let staleSessionThreshold:   TimeInterval = 15 * 60   // 15 minutes
    static let evictionDelay:           TimeInterval = 30 * 60   // 30 minutes
    static let approvalTimeoutSeconds:  TimeInterval = 25
    static let hookSocketTimeoutMs:     Int          = 150
    static let cloudKitDebounceMs:      Double       = 0.2
    static let eventRetentionDays:      Int          = 7
    static let sleepCommandTTL:         TimeInterval = 5 * 60    // 5 minutes
    static let sleepSyncIntervalSeconds: TimeInterval = 30
}
