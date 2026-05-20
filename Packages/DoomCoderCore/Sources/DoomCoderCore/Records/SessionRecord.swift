import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Per-session aggregate mirroring AgentTrackingManager.Session. Writer: Mac.
public struct SessionRecord: Sendable, Codable, Equatable {
    public var sessionKey: String     // "<agentRaw>::<sessionId>"
    public var macId: String
    public var agent: String          // TrackedAgent.rawValue
    public var sessionId: String
    public var cwd: String
    public var cwdBase: String?       // last path component (denorm for iOS)
    public var startedAt: Date
    public var updatedAt: Date
    public var lastEvent: String
    public var lastPhase: String
    public var lastTool: String?
    public var toolCallCount: Int
    public var errorCount: Int
    public var awaitingPermission: Bool
    public var hasEnded: Bool
    public var hasFailed: Bool
    public var displayState: String
    public var schemaVersion: Int

    public init(sessionKey: String, macId: String, agent: String, sessionId: String,
                cwd: String, cwdBase: String? = nil,
                startedAt: Date, updatedAt: Date,
                lastEvent: String, lastPhase: String, lastTool: String? = nil,
                toolCallCount: Int = 0, errorCount: Int = 0,
                awaitingPermission: Bool = false,
                hasEnded: Bool = false, hasFailed: Bool = false,
                displayState: String,
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.sessionKey = sessionKey
        self.macId = macId
        self.agent = agent
        self.sessionId = sessionId
        self.cwd = cwd
        self.cwdBase = cwdBase ?? NotificationCopy.shortCwd(cwd)
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastEvent = lastEvent
        self.lastPhase = lastPhase
        self.lastTool = lastTool
        self.toolCallCount = toolCallCount
        self.errorCount = errorCount
        self.awaitingPermission = awaitingPermission
        self.hasEnded = hasEnded
        self.hasFailed = hasFailed
        self.displayState = displayState
        self.schemaVersion = schemaVersion
    }
}

#if canImport(CloudKit)
extension SessionRecord {
    public static let recordType = CloudKitConstants.RecordType.session

    public var recordID: CKRecord.ID {
        let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        // Make recordName URL-safe (sessionKey contains '::' which is OK).
        let safe = sessionKey.replacingOccurrences(of: " ", with: "_")
        return CKRecord.ID(recordName: "Session-\(safe)", zoneID: zone)
    }

    public func toCKRecord() -> CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: recordID)
        r["sessionKey"]         = sessionKey as CKRecordValue
        r["macId"]              = macId as CKRecordValue
        r["agent"]              = agent as CKRecordValue
        r["sessionId"]          = sessionId as CKRecordValue
        r["cwd"]                = cwd as CKRecordValue
        if let b = cwdBase { r["cwdBase"] = b as CKRecordValue }
        r["startedAt"]          = startedAt as CKRecordValue
        r["updatedAt"]          = updatedAt as CKRecordValue
        r["lastEvent"]          = lastEvent as CKRecordValue
        r["lastPhase"]          = lastPhase as CKRecordValue
        if let t = lastTool { r["lastTool"] = t as CKRecordValue }
        r["toolCallCount"]      = toolCallCount as CKRecordValue
        r["errorCount"]         = errorCount as CKRecordValue
        r["awaitingPermission"] = (awaitingPermission ? 1 : 0) as CKRecordValue
        r["hasEnded"]           = (hasEnded ? 1 : 0) as CKRecordValue
        r["hasFailed"]          = (hasFailed ? 1 : 0) as CKRecordValue
        r["displayState"]       = displayState as CKRecordValue
        r["schemaVersion"]      = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let sessionKey = r["sessionKey"] as? String,
              let macId      = r["macId"]      as? String,
              let agent      = r["agent"]      as? String,
              let sessionId  = r["sessionId"]  as? String,
              let cwd        = r["cwd"]        as? String,
              let startedAt  = r["startedAt"]  as? Date,
              let updatedAt  = r["updatedAt"]  as? Date,
              let lastEvent  = r["lastEvent"]  as? String,
              let lastPhase  = r["lastPhase"]  as? String,
              let displayState = r["displayState"] as? String
        else { return nil }
        self.init(
            sessionKey: sessionKey, macId: macId, agent: agent, sessionId: sessionId,
            cwd: cwd, cwdBase: r["cwdBase"] as? String,
            startedAt: startedAt, updatedAt: updatedAt,
            lastEvent: lastEvent, lastPhase: lastPhase,
            lastTool: r["lastTool"] as? String,
            toolCallCount: (r["toolCallCount"] as? Int) ?? 0,
            errorCount: (r["errorCount"] as? Int) ?? 0,
            awaitingPermission: ((r["awaitingPermission"] as? Int) ?? 0) != 0,
            hasEnded: ((r["hasEnded"] as? Int) ?? 0) != 0,
            hasFailed: ((r["hasFailed"] as? Int) ?? 0) != 0,
            displayState: displayState,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
