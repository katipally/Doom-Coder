import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Single source of truth for CloudKit identifiers shared by Mac, iOS app and
/// NSE. Changing any value here is a schema-affecting change — coordinate
/// with the design plan before editing.
public enum CloudKitConstants {
    public static let containerIdentifier   = "iCloud.com.doomcoder.app"
    /// Legacy single-zone name (schema ≤2). Retained only for migration cleanup
    /// of the old private-DB-only model. New code uses per-Mac zones via
    /// `zoneName(forMacId:)`.
    public static let zoneName              = "DoomCoderZone"
    public static let appGroupIdentifier    = "group.com.doomcoder.app.companion"

    /// Per-Mac zone name. Each Mac owns its OWN zone so that two Macs on the
    /// SAME Apple ID don't collide on one shared zone (zoneID = name + owner;
    /// same owner + same name = same zone). The zone is shared zone-wide via a
    /// `CKShare(recordZoneID:)`; participants (iPhones) see it in their
    /// `sharedCloudDatabase`.
    public static func zoneName(forMacId macId: String) -> String {
        "DoomCoderZone-\(macId)"
    }

    public enum RecordType {
        public static let macStatus         = "MacStatus"
        public static let notificationLog   = "NotificationLog"
        public static let controlCommand    = "ControlCommand"
        public static let agentIcon         = "AgentIcon"
        public static let agentConfig       = "AgentConfig"
        public static let companionStatus   = "CompanionStatus"
    }

    /// Current schema version published to CloudKit. Bump together with field
    /// additions; old clients ignore unknown fields.
    /// v3: shared-zone + CKShare model (per-Mac zones, `customDeviceName`).
    public static let schemaVersion = 3
}
