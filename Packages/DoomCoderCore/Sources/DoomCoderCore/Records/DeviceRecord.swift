// DeviceRecord.swift — DoomCoderCore
//
// v7 revamp: the SINGLE presence/profile record for one device, written
// ONLY by that device into the shared DoomCoderZone. It replaces the four
// separate presence/state record types that preceded it:
//
//   MacStatusRecord            → DeviceRecord(role: .mac)
//   PeerStatusRecord           → DeviceRecord(role: .ios)
//   DiscoverableDeviceRecord   → still used, but only for *pre-pairing*
//                                same-iCloud discovery (public DB)
//   ConnectionStateChangeRecord→ deleted entirely; connection state is now
//                                DERIVED from which DeviceRecords are present
//                                in the zone and how fresh their `lastSeen` is.
//
// Because each device owns exactly one DeviceRecord (recordID is keyed by
// the device's own stable id) there is never an insert collision between
// devices, so there are no monotonic counters, no nonce suffixes, no
// etag self-heal loops, and no direct CKModifyRecordsOperation writes.
// Each side runs ONE CKSyncEngine per database, writes only its own record,
// and reads the whole zone. Same-iCloud and different-iCloud differ only in
// *which database* the engine is attached to — the record shape, the writes,
// and the reads are identical.
//
// Writer: the device the record describes. Readers: the paired peer
// (Mac reads the iPhone's record; iPhone reads the Mac's record), plus the
// NSE for the Mac name in notification subtitles.

import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

public enum DeviceRole: String, Codable, Sendable, Equatable, Hashable {
    case mac
    case ios
}

public struct DeviceRecord: Sendable, Codable, Equatable, Hashable, Identifiable {
    /// Stable id of the device this record describes (the Mac's macId or the
    /// iPhone's iosDeviceId). Drives the deterministic recordID.
    public var deviceId: String
    public var role: DeviceRole

    // MARK: Common profile (both roles)
    public var displayName: String          // "Yash's iPhone" / "Yash's MacBook Pro"
    public var model: String                // "iPhone 15 Pro" / "MacBookPro18,3"
    public var osVersion: String            // "iOS 19.0" / "macOS 26.0"
    public var appVersion: String           // "2.8.0 (14)"
    public var lastSeen: Date               // heartbeat; drives online/offline derivation

    /// Best-effort iCloud account identity (CloudKit discoverability). Nil if
    /// the user declined the prompt or it is undisclosed. Used for the
    /// "Name · email" subtitle on different-iCloud device cards.
    public var accountName: String?
    public var accountEmail: String?

    // MARK: iOS-only
    /// Battery level 0.0–1.0, or nil on the Mac / when unavailable.
    public var battery: Double?

    // MARK: Mac-only carry-overs (so existing Mac UI + Wake-on-LAN keep working)
    public var sleepActive: Bool?
    public var mode: String?                // DoomCoderMode rawValue
    public var thermalState: String?
    public var sessionEndsAt: Date?
    public var macAddress: String?
    public var broadcastIPv4: String?

    public var schemaVersion: Int

    public init(
        deviceId: String,
        role: DeviceRole,
        displayName: String,
        model: String,
        osVersion: String,
        appVersion: String,
        lastSeen: Date = Date(),
        accountName: String? = nil,
        accountEmail: String? = nil,
        battery: Double? = nil,
        sleepActive: Bool? = nil,
        mode: String? = nil,
        thermalState: String? = nil,
        sessionEndsAt: Date? = nil,
        macAddress: String? = nil,
        broadcastIPv4: String? = nil,
        schemaVersion: Int = CloudKitConstants.schemaVersion
    ) {
        self.deviceId = deviceId
        self.role = role
        self.displayName = displayName
        self.model = model
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.lastSeen = lastSeen
        self.accountName = accountName
        self.accountEmail = accountEmail
        self.battery = battery
        self.sleepActive = sleepActive
        self.mode = mode
        self.thermalState = thermalState
        self.sessionEndsAt = sessionEndsAt
        self.macAddress = macAddress
        self.broadcastIPv4 = broadcastIPv4
        self.schemaVersion = schemaVersion
    }

    public var id: String { deviceId }

    /// Online if the heartbeat is within `window` seconds of now.
    public func isOnline(window: TimeInterval = 120) -> Bool {
        Date().timeIntervalSince(lastSeen) <= window
    }
}

#if canImport(CloudKit)
extension DeviceRecord {
    public static let recordType = CloudKitConstants.RecordType.device

    /// `Device-<deviceId>` in the owner's DoomCoderZone. Deterministic so a
    /// device's repeated heartbeats UPDATE its single row (recordChangeTag
    /// preserved via ServerRecordCache) — never an accidental INSERT.
    public var recordID: CKRecord.ID { recordID(zoneOwner: CKCurrentUserDefaultName) }

    /// Returns the recordID in a specific zone owner's DoomCoderZone. Use
    /// `CKCurrentUserDefaultName` for the private-DB path (the Mac owner, or a
    /// same-iCloud iPhone whose engine is on its own private DB); pass the
    /// Mac's user record name for the shared-DB path (a different-iCloud
    /// iPhone writing into the Mac's shared zone). This zone-owner argument is
    /// the ONLY same/different-iCloud branch left in the model.
    public func recordID(zoneOwner: String) -> CKRecord.ID {
        let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: zoneOwner)
        return CKRecord.ID(recordName: "Device-\(deviceId)", zoneID: zone)
    }

    public func toCKRecord() -> CKRecord { toCKRecord(base: nil) }

    /// Builds the CKRecord, preserving the server `recordChangeTag` when
    /// `base` (the cached server record) is supplied so heartbeats are clean
    /// UPDATEs rather than colliding INSERTs.
    public func toCKRecord(base: CKRecord?) -> CKRecord {
        let r = base ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        fill(r)
        return r
    }

    /// Builds the CKRecord in a specific zone owner's zone (shared-DB path).
    public func toCKRecord(zoneOwner: String, base: CKRecord?) -> CKRecord {
        let r = base ?? CKRecord(recordType: Self.recordType, recordID: recordID(zoneOwner: zoneOwner))
        fill(r)
        return r
    }

    private func fill(_ r: CKRecord) {
        r["deviceId"]     = deviceId as CKRecordValue
        r["role"]         = role.rawValue as CKRecordValue
        r["displayName"]  = displayName as CKRecordValue
        r["model"]        = model as CKRecordValue
        r["osVersion"]    = osVersion as CKRecordValue
        r["appVersion"]   = appVersion as CKRecordValue
        r["lastSeen"]     = lastSeen as CKRecordValue
        r["accountName"]  = accountName.map { $0 as CKRecordValue }
        r["accountEmail"] = accountEmail.map { $0 as CKRecordValue }
        r["battery"]      = battery.map { $0 as CKRecordValue }
        r["sleepActive"]  = sleepActive.map { ($0 ? 1 : 0) as CKRecordValue }
        r["mode"]         = mode.map { $0 as CKRecordValue }
        r["thermalState"] = thermalState.map { $0 as CKRecordValue }
        r["sessionEndsAt"] = sessionEndsAt.map { $0 as CKRecordValue }
        r["macAddress"]   = macAddress.map { $0 as CKRecordValue }
        r["broadcastIPv4"] = broadcastIPv4.map { $0 as CKRecordValue }
        r["schemaVersion"] = schemaVersion as CKRecordValue
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let deviceId = r["deviceId"] as? String,
              let roleRaw  = r["role"] as? String,
              let role     = DeviceRole(rawValue: roleRaw)
        else { return nil }
        self.init(
            deviceId: deviceId,
            role: role,
            displayName: (r["displayName"] as? String) ?? (role == .mac ? "Mac" : "iPhone"),
            model:       (r["model"] as? String) ?? "",
            osVersion:   (r["osVersion"] as? String) ?? "",
            appVersion:  (r["appVersion"] as? String) ?? "",
            lastSeen:    (r["lastSeen"] as? Date) ?? Date(),
            accountName:  r["accountName"] as? String,
            accountEmail: r["accountEmail"] as? String,
            battery:     (r["battery"] as? Double),
            sleepActive: (r["sleepActive"] as? Int).map { $0 != 0 },
            mode:         r["mode"] as? String,
            thermalState: r["thermalState"] as? String,
            sessionEndsAt: r["sessionEndsAt"] as? Date,
            macAddress:   r["macAddress"] as? String,
            broadcastIPv4: r["broadcastIPv4"] as? String,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
