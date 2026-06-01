import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Snapshot of a companion device's live presence. One record per device,
/// keyed by a stable `deviceId`.
///
/// Writer: iOS/iPadOS companion (periodic heartbeat). Reader: Mac (Configure ▸
/// Connections tab) to show real connected/unreachable status per device,
/// symmetric to how the companion shows the Mac's status.
public struct CompanionStatusRecord: Sendable, Codable, Equatable {
    public var deviceId: String
    public var name: String
    public var model: String
    public var systemVersion: String
    public var appVersion: String
    public var lastSeen: Date
    public var schemaVersion: Int

    public init(deviceId: String,
                name: String,
                model: String,
                systemVersion: String,
                appVersion: String,
                lastSeen: Date = Date(),
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.deviceId = deviceId
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.lastSeen = lastSeen
        self.schemaVersion = schemaVersion
    }
}

#if canImport(CloudKit)
extension CompanionStatusRecord {
    public static let recordType = CloudKitConstants.RecordType.companionStatus

    public var recordID: CKRecord.ID {
        let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        return CKRecord.ID(recordName: "CompanionStatus-\(deviceId)", zoneID: zone)
    }

    public func toCKRecord() -> CKRecord { toCKRecord(base: nil) }

    /// Builds a CKRecord for this status. If `base` is provided (the server
    /// CKRecord cached from the most recent fetch/save), its
    /// `recordChangeTag` is preserved by mutating it in place — otherwise the
    /// second heartbeat fails with code 14/2004 ("record already exists").
    public func toCKRecord(base: CKRecord?) -> CKRecord {
        let r = base ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        r["deviceId"]      = deviceId as CKRecordValue
        r["name"]          = name as CKRecordValue
        r["model"]         = model as CKRecordValue
        r["systemVersion"] = systemVersion as CKRecordValue
        r["appVersion"]    = appVersion as CKRecordValue
        r["lastSeen"]      = lastSeen as CKRecordValue
        r["schemaVersion"] = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let deviceId = r["deviceId"] as? String,
              let name     = r["name"]     as? String,
              let lastSeen = r["lastSeen"] as? Date else { return nil }
        self.init(
            deviceId: deviceId,
            name: name,
            model: (r["model"] as? String) ?? "",
            systemVersion: (r["systemVersion"] as? String) ?? "",
            appVersion: (r["appVersion"] as? String) ?? "",
            lastSeen: lastSeen,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
