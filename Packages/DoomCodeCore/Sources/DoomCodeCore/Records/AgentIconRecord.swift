import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Per-agent icon record. One CKAsset per TrackedAgent. Writer: Mac (after
/// IconDownloader caches a PNG locally). iOS and the NSE read from the App
/// Group cache populated on first sync.
public struct AgentIconRecord: Sendable {
    public var agent: String          // TrackedAgent.rawValue
    public var pngSHA256: String
    #if canImport(CloudKit)
    public var pngAsset: CKAsset?
    #endif
    public var schemaVersion: Int

    public init(agent: String, pngSHA256: String,
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.agent = agent
        self.pngSHA256 = pngSHA256
        self.schemaVersion = schemaVersion
        #if canImport(CloudKit)
        self.pngAsset = nil
        #endif
    }
}

#if canImport(CloudKit)
extension AgentIconRecord {
    public static let recordType = CloudKitConstants.RecordType.agentIcon

    public static func recordID(for agent: String, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "AgentIcon-\(agent)", zoneID: zoneID)
    }

    public func toCKRecord(in zoneID: CKRecordZone.ID, pngFileURL: URL) -> CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: Self.recordID(for: agent, in: zoneID))
        r["agent"]         = agent as CKRecordValue
        r["pngSHA256"]     = pngSHA256 as CKRecordValue
        r["pngAsset"]      = CKAsset(fileURL: pngFileURL)
        r["schemaVersion"] = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let agent     = r["agent"]     as? String,
              let pngSHA256 = r["pngSHA256"] as? String
        else { return nil }
        self.init(agent: agent, pngSHA256: pngSHA256,
                  schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion)
        self.pngAsset = r["pngAsset"] as? CKAsset
    }
}
#endif
