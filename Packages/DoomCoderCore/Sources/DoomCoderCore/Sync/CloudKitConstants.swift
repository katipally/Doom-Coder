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
        /// v5: written by either side when a Connection transitions
        /// state. The other side's CKSyncEngine subscribes to
        /// DoomCoderZone and receives an APNs silent push within 1–3s,
        /// giving us instant cross-device pairing-state sync.
        public static let connectionStateChange = "ConnectionStateChange"
        /// v5.1: public-DB record type. The Mac publishes one of these
        /// per device, and the iOS companion subscribes to a
        /// CKQuerySubscription to render a "discoverable Macs" list
        /// in the Add Mac sheet's "Same iCloud" tab. Mac is the
        /// source of truth; iPhones are passive. Records live in the
        /// public DB so they don't require an iCloud account on the
        /// iOS side to read — only to verify same-iCloud via the
        /// creatorUserRecordID on the resulting CSC.
        public static let discoverableMac    = "DiscoverableMac"
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
    ///   5 - added ConnectionStateChange record type. The new record is
    ///       written by either side whenever a Connection transitions
    ///       (accepted / suspended / removed / reinstall-detected).
    ///       The other side's CKSyncEngine subscribes to DoomCoderZone
    ///       and picks the change up within 1–3s via APNs silent push,
    ///       giving us instant cross-device state sync without polling.
    ///       Additive fields only: PeerStatus gains `routeAccountEmail`
    ///       and `stateChangeCounter`. Connection (local-only) gains
    ///       `pairingOrigin`, `stateChangeCounter`, `removedAt`,
    ///       `shareAcceptedAt`. Old clients ignore the new record type
    ///       and the new fields.
    public static let schemaVersion = 5
}
