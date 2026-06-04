// PeerStatusRecord.swift — DoomCoderCore
//
// Heartbeat record written by the iOS companion so the Mac can see the
// peer in its Connections list. Symmetric to MacStatusRecord (which
// Mac writes and iOS reads). With both directions of status flowing
// through the same DoomCoderZone, the two sides stay in lock-step and
// the user sees the same connection state on both devices.
//
// v2.7: this is the record that fixes the long-standing asymmetry
// where the iOS companion knew the Mac was connected but the Mac's
// Connections tab showed "No paired devices".
//
// Writer: iOS. Readers: Mac (Connections tab, device details).

import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

public struct PeerStatusRecord: Sendable, Codable, Equatable {
    public var iosDeviceId: String
    public var name: String                 // e.g. "Yash's iPhone"
    public var model: String                // e.g. "iPhone 17 Pro Max"
    public var systemName: String           // e.g. "iOS 26.4"
    public var appVersion: String           // e.g. "2.7.0 (12)"
    public var lastSeen: Date
    /// "iCloud" or "iCloud Share" — informational, surfaces in the
    /// Mac's DeviceRow so the user knows which route this peer is on.
    public var route: String
    /// Stable per-Mac identifier the iOS app learned from the most
    /// recent MacStatusRecord it received. Lets the Mac know which of
    /// its paired Macs this iOS device is talking to (matters when
    /// multiple Macs are paired to the same iCloud).
    public var macId: String?
    /// v2.8: included when the iOS app has an explicit CKShare
    /// connection. Lets the Mac reconcile a placeholder ckShare
    /// Connection row (created with a random iosDeviceId at
    /// handleAcceptance time) with the real iosDeviceId from the
    /// first heartbeat — without creating a duplicate row.
    public var shareURLString: String?
    public var schemaVersion: Int

    public init(
        iosDeviceId: String,
        name: String,
        model: String,
        systemName: String,
        appVersion: String,
        lastSeen: Date = Date(),
        route: String,
        macId: String? = nil,
        shareURLString: String? = nil,
        schemaVersion: Int = CloudKitConstants.schemaVersion
    ) {
        self.iosDeviceId = iosDeviceId
        self.name = name
        self.model = model
        self.systemName = systemName
        self.appVersion = appVersion
        self.lastSeen = lastSeen
        self.route = route
        self.macId = macId
        self.shareURLString = shareURLString
        self.schemaVersion = schemaVersion
    }
}

#if canImport(CloudKit)
extension PeerStatusRecord {
    public static let recordType = CloudKitConstants.RecordType.peerStatus

    /// One record per (mac, ios) pair, keyed deterministically so
    /// heartbeat saves preserve `recordChangeTag` (CKError 14/2004
    /// prevention — same lesson baked into MacStatusRecord).
    public var recordID: CKRecord.ID {
        let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        // When the iOS app doesn't yet know which Mac it's paired to
        // (e.g. very first launch, before any MacStatus has been
        // fetched), use a stable "unknown" slot. The Mac can still
        // discover this peer; the Connection's macDeviceId is the
        // Mac's own ID, not the peer's.
        let macSegment = macId ?? "unknown"
        return CKRecord.ID(recordName: "PeerStatus-\(macSegment)-\(iosDeviceId)", zoneID: zone)
    }

    public func toCKRecord() -> CKRecord { toCKRecord(base: nil) }

    public func toCKRecord(base: CKRecord?) -> CKRecord {
        let r = base ?? CKRecord(recordType: Self.recordType, recordID: recordID)
        r["iosDeviceId"]  = iosDeviceId as CKRecordValue
        r["name"]         = name as CKRecordValue
        r["model"]        = model as CKRecordValue
        r["systemName"]   = systemName as CKRecordValue
        r["appVersion"]   = appVersion as CKRecordValue
        r["lastSeen"]     = lastSeen as CKRecordValue
        r["route"]        = route as CKRecordValue
        if let m = macId { r["macId"] = m as CKRecordValue } else { r["macId"] = nil }
        if let s = shareURLString { r["shareURLString"] = s as CKRecordValue } else { r["shareURLString"] = nil }
        r["schemaVersion"] = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let iosDeviceId = r["iosDeviceId"] as? String
        else { return nil }
        self.init(
            iosDeviceId: iosDeviceId,
            name:        (r["name"]       as? String) ?? "iPhone",
            model:       (r["model"]      as? String) ?? "",
            systemName:  (r["systemName"] as? String) ?? "",
            appVersion:  (r["appVersion"] as? String) ?? "",
            lastSeen:    (r["lastSeen"]   as? Date)   ?? Date(),
            route:       (r["route"]      as? String) ?? "iCloud",
            macId:        r["macId"]       as? String,
            shareURLString: r["shareURLString"] as? String,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
