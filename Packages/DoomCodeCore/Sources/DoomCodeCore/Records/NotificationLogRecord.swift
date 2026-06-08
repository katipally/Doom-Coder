import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Notification dispatch record. Writer: Mac. One per emitted notification.
/// The iOS app subscribes to this record type (CKQuerySubscription) so each
/// creation produces a user-visible push that the NSE renders.
public struct NotificationLogRecord: Sendable, Codable, Equatable {
    public var notifId: String
    public var sessionKey: String
    public var macId: String
    public var macName: String
    public var agent: String
    public var phase: String
    public var rawEvent: String
    public var title: String
    public var body: String
    public var channel: String        // "macOS" | "iOS"
    public var success: Bool
    public var ts: Date
    /// Denormalised fields used by the NSE without needing a CloudKit fetch.
    public var lastTool: String?
    public var cwdBase: String?
    public var schemaVersion: Int

    public init(notifId: String = UUID().uuidString,
                sessionKey: String, macId: String, macName: String,
                agent: String, phase: String, rawEvent: String,
                title: String, body: String,
                channel: String, success: Bool, ts: Date,
                lastTool: String? = nil, cwdBase: String? = nil,
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.notifId = notifId
        self.sessionKey = sessionKey
        self.macId = macId
        self.macName = macName
        self.agent = agent
        self.phase = phase
        self.rawEvent = rawEvent
        self.title = title
        self.body = body
        self.channel = channel
        self.success = success
        self.ts = ts
        self.lastTool = lastTool
        self.cwdBase = cwdBase
        self.schemaVersion = schemaVersion
    }
}

#if canImport(CloudKit)
extension NotificationLogRecord {
    public static let recordType = CloudKitConstants.RecordType.notificationLog

    /// Record ID within a specific zone. The owner Mac passes its own zoneID.
    public func recordID(in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "NotificationLog-\(notifId)", zoneID: zoneID)
    }

    public func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: recordID(in: zoneID))
        r["notifId"]    = notifId as CKRecordValue
        r["sessionKey"] = sessionKey as CKRecordValue
        r["macId"]      = macId as CKRecordValue
        r["macName"]    = macName as CKRecordValue
        r["agent"]      = agent as CKRecordValue
        r["phase"]      = phase as CKRecordValue
        r["rawEvent"]   = rawEvent as CKRecordValue
        r["title"]      = title as CKRecordValue
        r["body"]       = body as CKRecordValue
        r["channel"]    = channel as CKRecordValue
        r["success"]    = (success ? 1 : 0) as CKRecordValue
        r["ts"]         = ts as CKRecordValue
        if let t = lastTool { r["lastTool"] = t as CKRecordValue }
        if let c = cwdBase  { r["cwdBase"]  = c as CKRecordValue }
        r["schemaVersion"] = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let notifId    = r["notifId"]    as? String,
              let sessionKey = r["sessionKey"] as? String,
              let macId      = r["macId"]      as? String,
              let macName    = r["macName"]    as? String,
              let agent      = r["agent"]      as? String,
              let phase      = r["phase"]      as? String,
              let rawEvent   = r["rawEvent"]   as? String,
              let title      = r["title"]      as? String,
              let body       = r["body"]       as? String,
              let channel    = r["channel"]    as? String,
              let ts         = r["ts"]         as? Date
        else { return nil }
        self.init(
            notifId: notifId, sessionKey: sessionKey, macId: macId, macName: macName,
            agent: agent, phase: phase, rawEvent: rawEvent,
            title: title, body: body, channel: channel,
            success: ((r["success"] as? Int) ?? 1) != 0,
            ts: ts,
            lastTool: r["lastTool"] as? String,
            cwdBase: r["cwdBase"] as? String,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
