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
        public static let wolProfile        = "WoLProfile"
        public static let agentIcon         = "AgentIcon"
        public static let agentConfig       = "AgentConfig"
        public static let peerStatus        = "PeerStatus"
        /// Public-DB only. Temporary record keyed by 6-char pairing code.
        /// TTL matches PairingCode.lifetime (10 min). Mac writes it, iOS reads it.
        public static let pairingCode       = "DCPairingCode"
    }

    /// Current schema version published to CloudKit. Bump together with field
    /// additions; old clients ignore unknown fields.
    ///
    /// History:
    ///   1 - initial release (MacStatus, NotificationLog, AgentConfig)
    ///   2 - added AgentIcon, WoLProfile
    ///   3 - added Route/CKShare piggybacking. No wire-format change to
    ///       existing records; the new schema field is consumed by clients
    ///       that understand cross-Apple-ID pairing. Old clients continue
    ///       to work and ignore the new field.
    ///   4 - added PeerStatus (iOS → Mac heartbeat). Symmetric with
    ///       MacStatus so the Mac's Connections tab knows which iOS
    ///       devices are currently paired. Wire format unchanged for
    ///       all pre-existing record types; old clients ignore the new
    ///       PeerStatus records entirely.
    public static let schemaVersion = 4
}
