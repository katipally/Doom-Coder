import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Append-only timeline event. One record per ingested hook event.
/// Writer: Mac.
public struct EventRecord: Sendable, Codable, Equatable {
    public var eventId: String        // UUID-ish stable id
    public var sessionKey: String
    public var macId: String
    public var agent: String
    public var rawEvent: String
    public var phase: String
    public var tool: String?
    public var path: String?
    public var ts: Date
    /// SHA-256 of the payload, present when payload-snippet privacy tier 3 is OFF.
    public var payloadDigest: String?
    /// Optional truncated payload snippet (tier 3 opt-in).
    public var payloadSnippet: String?
    public var schemaVersion: Int

    public init(eventId: String = UUID().uuidString,
                sessionKey: String, macId: String, agent: String,
                rawEvent: String, phase: String,
                tool: String? = nil, path: String? = nil,
                ts: Date,
                payloadDigest: String? = nil,
                payloadSnippet: String? = nil,
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.eventId = eventId
        self.sessionKey = sessionKey
        self.macId = macId
        self.agent = agent
        self.rawEvent = rawEvent
        self.phase = phase
        self.tool = tool
        self.path = path
        self.ts = ts
        self.payloadDigest = payloadDigest
        self.payloadSnippet = payloadSnippet
        self.schemaVersion = schemaVersion
    }
}

#if canImport(CloudKit)
extension EventRecord {
    public static let recordType = CloudKitConstants.RecordType.event

    public var recordID: CKRecord.ID {
        let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        return CKRecord.ID(recordName: "Event-\(eventId)", zoneID: zone)
    }

    public func toCKRecord() -> CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: recordID)
        r["eventId"]        = eventId as CKRecordValue
        r["sessionKey"]     = sessionKey as CKRecordValue
        r["macId"]          = macId as CKRecordValue
        r["agent"]          = agent as CKRecordValue
        r["rawEvent"]       = rawEvent as CKRecordValue
        r["phase"]          = phase as CKRecordValue
        if let t = tool { r["tool"] = t as CKRecordValue }
        if let p = path { r["path"] = p as CKRecordValue }
        r["ts"]             = ts as CKRecordValue
        if let d = payloadDigest  { r["payloadDigest"]  = d as CKRecordValue }
        if let s = payloadSnippet { r["payloadSnippet"] = s as CKRecordValue }
        r["schemaVersion"]  = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let eventId    = r["eventId"]    as? String,
              let sessionKey = r["sessionKey"] as? String,
              let macId      = r["macId"]      as? String,
              let agent      = r["agent"]      as? String,
              let rawEvent   = r["rawEvent"]   as? String,
              let phase      = r["phase"]      as? String,
              let ts         = r["ts"]         as? Date
        else { return nil }
        self.init(
            eventId: eventId, sessionKey: sessionKey, macId: macId, agent: agent,
            rawEvent: rawEvent, phase: phase,
            tool: r["tool"] as? String,
            path: r["path"] as? String,
            ts: ts,
            payloadDigest: r["payloadDigest"] as? String,
            payloadSnippet: r["payloadSnippet"] as? String,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
