import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Wake-on-LAN profile for a single Mac. Written by Mac on launch + every
/// Wi-Fi change. Read by iOS to construct magic packets when on the same LAN.
public struct WoLProfileRecord: Sendable, Codable, Equatable {
    public var macId: String
    public var macName: String
    /// All non-loopback interface MAC addresses (lowercased, colon-separated).
    public var macAddresses: [String]
    /// SSID hints for "same-LAN" detection. May be empty if Location
    /// permission was never granted on the Mac.
    public var lanSSIDs: [String]
    /// `pmset -g | grep womp == 1` — Wake-for-network-access enabled.
    public var wakeForNetworkAccessEnabled: Bool
    public var lastSeenAt: Date
    public var schemaVersion: Int

    public init(macId: String, macName: String,
                macAddresses: [String], lanSSIDs: [String],
                wakeForNetworkAccessEnabled: Bool,
                lastSeenAt: Date = Date(),
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.macId = macId
        self.macName = macName
        self.macAddresses = macAddresses
        self.lanSSIDs = lanSSIDs
        self.wakeForNetworkAccessEnabled = wakeForNetworkAccessEnabled
        self.lastSeenAt = lastSeenAt
        self.schemaVersion = schemaVersion
    }
}

#if canImport(CloudKit)
extension WoLProfileRecord {
    public static let recordType = CloudKitConstants.RecordType.wolProfile

    public var recordID: CKRecord.ID {
        let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        return CKRecord.ID(recordName: "WoLProfile-\(macId)", zoneID: zone)
    }

    public func toCKRecord() -> CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: recordID)
        r["macId"]                       = macId as CKRecordValue
        r["macName"]                     = macName as CKRecordValue
        r["macAddresses"]                = macAddresses as CKRecordValue
        r["lanSSIDs"]                    = lanSSIDs as CKRecordValue
        r["wakeForNetworkAccessEnabled"] = (wakeForNetworkAccessEnabled ? 1 : 0) as CKRecordValue
        r["lastSeenAt"]                  = lastSeenAt as CKRecordValue
        r["schemaVersion"]               = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let macId        = r["macId"]        as? String,
              let macName      = r["macName"]      as? String,
              let macAddresses = r["macAddresses"] as? [String],
              let lastSeenAt   = r["lastSeenAt"]   as? Date
        else { return nil }
        self.init(
            macId: macId, macName: macName,
            macAddresses: macAddresses,
            lanSSIDs: (r["lanSSIDs"] as? [String]) ?? [],
            wakeForNetworkAccessEnabled: ((r["wakeForNetworkAccessEnabled"] as? Int) ?? 0) != 0,
            lastSeenAt: lastSeenAt,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
