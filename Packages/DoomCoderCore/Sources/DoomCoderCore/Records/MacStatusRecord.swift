import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Snapshot of a Mac's live state. One record per Mac, keyed by `macId`
/// (a stable identifier derived from the IOPlatformUUID).
///
/// Writer: Mac. Readers: iOS (Home tab header), NSE (notification subtitle
/// shows "<macName>").
public struct MacStatusRecord: Sendable, Codable, Equatable {
    public var macId: String
    public var name: String
    public var version: String
    public var sleepActive: Bool
    public var mode: String          // DoomCoderMode rawValue: "screenOn" | "screenOff"
    public var sessionEndsAt: Date?
    public var lastSeen: Date
    public var thermalState: String
    public var schemaVersion: Int

    public init(macId: String,
                name: String,
                version: String,
                sleepActive: Bool,
                mode: String,
                sessionEndsAt: Date? = nil,
                lastSeen: Date = Date(),
                thermalState: String = "Normal",
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.macId = macId
        self.name = name
        self.version = version
        self.sleepActive = sleepActive
        self.mode = mode
        self.sessionEndsAt = sessionEndsAt
        self.lastSeen = lastSeen
        self.thermalState = thermalState
        self.schemaVersion = schemaVersion
    }
}

#if canImport(CloudKit)
extension MacStatusRecord {
    public static let recordType = CloudKitConstants.RecordType.macStatus

    public var recordID: CKRecord.ID {
        let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        return CKRecord.ID(recordName: "MacStatus-\(macId)", zoneID: zone)
    }

    public func toCKRecord() -> CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: recordID)
        r["macId"]         = macId as CKRecordValue
        r["name"]          = name as CKRecordValue
        r["version"]       = version as CKRecordValue
        r["sleepActive"]   = (sleepActive ? 1 : 0) as CKRecordValue
        r["mode"]          = mode as CKRecordValue
        if let e = sessionEndsAt { r["sessionEndsAt"] = e as CKRecordValue }
        r["lastSeen"]      = lastSeen as CKRecordValue
        r["thermalState"]  = thermalState as CKRecordValue
        r["schemaVersion"] = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let macId    = r["macId"]   as? String,
              let name     = r["name"]    as? String,
              let version  = r["version"] as? String,
              let mode     = r["mode"]    as? String,
              let lastSeen = r["lastSeen"] as? Date else { return nil }
        let sleepActive = ((r["sleepActive"] as? Int) ?? 0) != 0
        self.init(
            macId: macId, name: name, version: version,
            sleepActive: sleepActive, mode: mode,
            sessionEndsAt: r["sessionEndsAt"] as? Date,
            lastSeen: lastSeen,
            thermalState: (r["thermalState"] as? String) ?? "Normal",
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
