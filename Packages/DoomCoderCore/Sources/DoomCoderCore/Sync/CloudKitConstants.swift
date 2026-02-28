import Foundation

/// Single source of truth for CloudKit identifiers shared by Mac, iOS app and
/// NSE. Changing any value here is a schema-affecting change — coordinate
/// with §12.5 of the design plan before editing.
public enum CloudKitConstants {
    public static let containerIdentifier   = "iCloud.com.doomcoder.app"
    public static let zoneName              = "DoomCoderZone"
    public static let appGroupIdentifier    = "group.com.doomcoder.app.companion"

    public enum RecordType {
        public static let macStatus         = "MacStatus"
        public static let settings          = "Settings"
        public static let session           = "Session"
        public static let event             = "Event"
        public static let notificationLog   = "NotificationLog"
        public static let controlCommand    = "ControlCommand"
        public static let wolProfile        = "WoLProfile"
        public static let agentIcon         = "AgentIcon"
        public static let agentConfig       = "AgentConfig"
        public static let companionStatus   = "CompanionStatus"
    }

    /// Current schema version published to CloudKit. Bump together with field
    /// additions; old clients ignore unknown fields.
    public static let schemaVersion = 2
}
