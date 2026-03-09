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
    /// User-facing display name. Since iOS 16 `UIDevice.current.name` returns a
    /// generic string ("iPhone") without an Apple-approval-gated entitlement, so
    /// this is the user-typed custom name when set, falling back to the marketing
    /// model name (see `customDeviceName`).
    public var name: String
    public var model: String
    public var systemVersion: String
    public var appVersion: String
    /// The user-typed custom device name, if any. When empty the Mac displays
    /// `model` (the marketing name, e.g. "iPhone 17 Pro"). Distinct from `name`
    /// so the Mac can show "Custom Name · iPhone 17 Pro".
    public var customDeviceName: String
    public var lastSeen: Date
    public var schemaVersion: Int

    public init(deviceId: String,
                name: String,
                model: String,
                systemVersion: String,
                appVersion: String,
                customDeviceName: String = "",
                lastSeen: Date = Date(),
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.deviceId = deviceId
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.customDeviceName = customDeviceName
        self.lastSeen = lastSeen
        self.schemaVersion = schemaVersion
    }

    /// The best display name for this device: the user's custom name if set,
    /// else the marketing model name, else the generic `name`.
    public var displayName: String {
        if !customDeviceName.isEmpty { return customDeviceName }
        if !model.isEmpty { return model }
        return name
    }
}

#if canImport(CloudKit)
extension CompanionStatusRecord {
    public static let recordType = CloudKitConstants.RecordType.companionStatus

    /// Record ID within a specific zone. The iPhone (participant) passes the
    /// TARGET Mac's zoneID (owner = that Mac), learned from the share / fetched
    /// MacStatus record.
    public func recordID(in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "CompanionStatus-\(deviceId)", zoneID: zoneID)
    }

    /// Builds a CKRecord for this status in `zoneID`. If `base` is provided (the
    /// server CKRecord cached from the most recent fetch/save), its
    /// `recordChangeTag` is preserved by mutating it in place — otherwise the
    /// second heartbeat fails with code 14/2004 ("record already exists").
    public func toCKRecord(in zoneID: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let r = base ?? CKRecord(recordType: Self.recordType, recordID: recordID(in: zoneID))
        r["deviceId"]         = deviceId as CKRecordValue
        r["name"]             = name as CKRecordValue
        r["model"]            = model as CKRecordValue
        r["systemVersion"]    = systemVersion as CKRecordValue
        r["appVersion"]       = appVersion as CKRecordValue
        r["customDeviceName"] = customDeviceName as CKRecordValue
        r["lastSeen"]         = lastSeen as CKRecordValue
        r["schemaVersion"]    = schemaVersion as CKRecordValue
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
            customDeviceName: (r["customDeviceName"] as? String) ?? "",
            lastSeen: lastSeen,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
