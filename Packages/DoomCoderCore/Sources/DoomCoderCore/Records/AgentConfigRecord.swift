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
    /// JSON-encoded `[String: [AgentDeliverable]]` mapping agent rawValue → the
    /// "what you'll be notified about" rows the user has enabled on this Mac.
    /// iOS renders these read-only. Empty when not yet published (older Macs).
    public var deliverables: String
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(macId: String,
                agents: [String],
                installedAgents: [String] = [],
                statuses: String = "",
                deliverables: String = "",
                updatedAt: Date = Date(),
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.macId = macId
        self.agents = agents
        self.installedAgents = installedAgents
        self.statuses = statuses
        self.deliverables = deliverables
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    // MARK: - Typed accessor (audit 2026-06)

    /// Decodes the `statuses` JSON blob into a typed `[String: String]`.
    /// Returns an empty dictionary when the JSON is missing, malformed, or
    /// `statuses` is empty. The contract for the string is documented on
    /// the `statuses` property above: writers MUST pass a JSON-encoded
    /// `[String: String]` (use `agentStatusesJSON(from:)` to encode one).
    public var agentStatuses: [String: String] {
        guard !statuses.isEmpty,
              let data = statuses.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return decoded
    }

    /// Decodes the `deliverables` JSON blob into a typed map of agent rawValue →
    /// enabled notification rows. Returns an empty dictionary when missing or
    /// malformed. Use `agentDeliverablesJSON(from:)` to encode one for writing.
    public var agentDeliverables: [String: [AgentDeliverable]] {
        guard !deliverables.isEmpty,
              let data = deliverables.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [AgentDeliverable]].self, from: data)
        else { return [:] }
        return decoded
    }

    /// JSON-encodes a typed deliverables map for storage in `deliverables`.
    public static func agentDeliverablesJSON(from map: [String: [AgentDeliverable]]) -> String {
        guard !map.isEmpty,
              let data = try? JSONEncoder().encode(map),
              let str = String(data: data, encoding: .utf8)
        else { return "" }
        return str
    }

    /// Convenience initializer that takes a typed `[String: String]` and
    /// JSON-encodes it for storage. Use this instead of constructing the
    /// record with a literal `statuses: ""` when you have actual status
    /// data.
    public init(macId: String,
                agents: [String],
                installedAgents: [String] = [],
                agentStatuses: [String: String] = [:],
                agentDeliverables: [String: [AgentDeliverable]] = [:],
                updatedAt: Date = Date(),
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        let json = (try? JSONSerialization.data(withJSONObject: agentStatuses, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        self.init(
            macId: macId,
            agents: agents,
            installedAgents: installedAgents,
            statuses: json,
            deliverables: Self.agentDeliverablesJSON(from: agentDeliverables),
            updatedAt: updatedAt,
            schemaVersion: schemaVersion
        )
    }
}

#if canImport(CloudKit)
extension AgentConfigRecord {
    public static let recordType = CloudKitConstants.RecordType.agentConfig

    /// Record ID within a specific zone. The owner Mac passes its own zoneID.
    public func recordID(in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "AgentConfig-\(macId)", zoneID: zoneID)
    }

    /// Pass the server-cached `base` to preserve `recordChangeTag` and avoid
    /// CKError 14/2004 on the second save.
    public func toCKRecord(in zoneID: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let r = base ?? CKRecord(recordType: Self.recordType, recordID: recordID(in: zoneID))
        r["macId"]           = macId as CKRecordValue
        r["agents"]          = agents as CKRecordValue
        r["installedAgents"] = installedAgents as CKRecordValue
        r["statuses"]        = statuses as CKRecordValue
        r["deliverables"]    = deliverables as CKRecordValue
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
            deliverables: (r["deliverables"] as? String) ?? "",
            updatedAt: updatedAt,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
