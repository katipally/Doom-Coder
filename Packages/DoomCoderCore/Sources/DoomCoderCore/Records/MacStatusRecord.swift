import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Snapshot of a Mac's live state. One record per Mac, keyed by `macId`
/// (a stable identifier derived from the IOPlatformUUID).
///
/// Writer: Mac. Readers: iOS (Dashboard tab), NSE (notification subtitle
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
    /// Primary Ethernet/Wi-Fi MAC address ("aa:bb:cc:dd:ee:ff") so the
    /// iOS companion can send a magic packet over the local subnet when
    /// the Mac is asleep. Optional — over cellular WoL is impossible
    /// anyway and APNs wake-for-network is the canonical wake path.
    public var macAddress: String?
    /// IPv4 broadcast address of the primary interface (e.g. "192.168.1.255")
    /// so the magic packet reaches the correct subnet.
    public var broadcastIPv4: String?
    /// v6: the Mac's iCloud account display name + email (CloudKit
    /// discoverability). Best-effort — nil if the user declined the prompt.
    /// Lets the iPhone show "MacBook Pro · Yashwanth · you@icloud.com".
    public var accountFullName: String?
    public var accountEmail: String?

    public init(macId: String,
                name: String,
                version: String,
                sleepActive: Bool,
                mode: String,
                sessionEndsAt: Date? = nil,
                lastSeen: Date = Date(),
                thermalState: String = "Normal",
                macAddress: String? = nil,
                broadcastIPv4: String? = nil,
                accountFullName: String? = nil,
                accountEmail: String? = nil,
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.macId = macId
        self.name = name
        self.version = version
        self.sleepActive = sleepActive
        self.mode = mode
        self.sessionEndsAt = sessionEndsAt
        self.lastSeen = lastSeen
        self.thermalState = thermalState
        self.macAddress = macAddress
        self.broadcastIPv4 = broadcastIPv4
        self.accountFullName = accountFullName
        self.accountEmail = accountEmail
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

    public func toCKRecord() -> CKRecord { toCKRecord(base: nil) }

    /// Builds a CKRecord for this status. If `base` is provided (the server
    /// CKRecord cached from the most recent fetch/save), its
    /// `recordChangeTag` is preserved by mutating it in place. Without the
    /// tag, every heartbeat looks like an INSERT to CloudKit and the second
    /// one fails with code 14/2004 ("record to insert already exists").
    public func toCKRecord(base: CKRecord?) -> CKRecord {
        let r = base ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        r["macId"]         = macId as CKRecordValue
        r["name"]          = name as CKRecordValue
        r["version"]       = version as CKRecordValue
        r["sleepActive"]   = (sleepActive ? 1 : 0) as CKRecordValue
        r["mode"]          = mode as CKRecordValue
        if let e = sessionEndsAt { r["sessionEndsAt"] = e as CKRecordValue }
        else { r["sessionEndsAt"] = nil }
        r["lastSeen"]      = lastSeen as CKRecordValue
        r["thermalState"]  = thermalState as CKRecordValue
        if let m = macAddress { r["macAddress"] = m as CKRecordValue } else { r["macAddress"] = nil }
        if let b = broadcastIPv4 { r["broadcastIPv4"] = b as CKRecordValue } else { r["broadcastIPv4"] = nil }
        if let n = accountFullName { r["accountFullName"] = n as CKRecordValue } else { r["accountFullName"] = nil }
        if let e = accountEmail { r["accountEmail"] = e as CKRecordValue } else { r["accountEmail"] = nil }
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
            macAddress: r["macAddress"] as? String,
            broadcastIPv4: r["broadcastIPv4"] as? String,
            accountFullName: r["accountFullName"] as? String,
            accountEmail: r["accountEmail"] as? String,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
