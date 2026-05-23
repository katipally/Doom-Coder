import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// List of configured (tracked) agents on a Mac. One record per Mac, keyed by
/// `macId`. Writer: Mac. Reader: iOS (drives the agent list UI).
///
/// `agents` is the array of `TrackedAgent.rawValue` strings the user has
/// enabled on this Mac. iOS renders these in order.
public struct AgentConfigRecord: Sendable, Codable, Equatable {
    public var macId: String
    public var agents: [String]
    /// Subset of `TrackedAgent.allCases` rawValues currently installed on this Mac.
    /// Drives the "not installed" badge on iOS.
    public var installedAgents: [String]
    /// JSON-encoded `[String: String]` mapping agent rawValue → human-readable
    /// status (e.g. "running", "waiting for approval", "closed"). Empty when
    /// status tracking is unavailable.
    public var statuses: String
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(macId: String,
                agents: [String],
                installedAgents: [String] = [],
                statuses: String = "",
                updatedAt: Date = Date(),
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.macId = macId
        self.agents = agents
        self.installedAgents = installedAgents
        self.statuses = statuses
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

#if canImport(CloudKit)
extension AgentConfigRecord {
    public static let recordType = CloudKitConstants.RecordType.agentConfig

    public var recordID: CKRecord.ID {
        let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        return CKRecord.ID(recordName: "AgentConfig-\(macId)", zoneID: zone)
    }

    public func toCKRecord() -> CKRecord { toCKRecord(base: nil) }

    /// Pass the server-cached `base` to preserve `recordChangeTag` and avoid
    /// CKError 14/2004 on the second save.
    public func toCKRecord(base: CKRecord?) -> CKRecord {
        let r = base ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        r["macId"]           = macId as CKRecordValue
        r["agents"]          = agents as CKRecordValue
        r["installedAgents"] = installedAgents as CKRecordValue
        r["statuses"]        = statuses as CKRecordValue
        r["updatedAt"]       = updatedAt as CKRecordValue
        r["schemaVersion"]   = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let macId     = r["macId"]     as? String,
              let agents    = r["agents"]    as? [String],
              let updatedAt = r["updatedAt"] as? Date
        else { return nil }
        self.init(
            macId: macId, agents: agents,
            installedAgents: (r["installedAgents"] as? [String]) ?? [],
            statuses: (r["statuses"] as? String) ?? "",
            updatedAt: updatedAt,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
