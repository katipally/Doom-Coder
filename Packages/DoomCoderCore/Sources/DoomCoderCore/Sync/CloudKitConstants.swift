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
        /// Public-DB only. Temporary record keyed by 6-char pairing code.
        /// TTL matches PairingCode.lifetime (10 min). Mac writes it, iOS reads it.
        public static let pairingCode       = "DCPairingCode"
        /// v6: public-DB record published by the iOS companion so the Mac can
        /// list this account's iPhones in its Add-Device "Same iCloud" tab.
        /// Mirrors DiscoverableMac but in the opposite direction — the Mac is
        /// now the initiator of same-iCloud pairing, the iPhone the acceptor.
        /// Keyed by the iPhone's iosDeviceId; carries the publisher's
        /// userRecordID so the Mac can verify same-iCloud before requesting.
        public static let discoverableDevice = "DiscoverableDevice"
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
    ///   6 - Mac-initiates-everywhere rebuild. Additive only:
    ///       ConnectionStateChange gains `state = "requested"` and a
    ///       `macUserRecordID` field; PeerStatus/MacStatus gain
    ///       `accountFullName`/`accountEmail` (CloudKit discoverability
    ///       identity); new `DiscoverableDevice` public-DB record type
    ///       (iPhone presence the Mac discovers). Old clients ignore the
    ///       new state/fields/record type.
    public static let schemaVersion = 6
}
