// DiscoverableDeviceRecord.swift — DoomCoderCore
// v6: iPhone presence record for the Mac's Add-Device "Same iCloud" picker.
//
// In the v6 model the MAC is the initiator of every pairing (QR, code,
// link, and same-iCloud). For the same-iCloud flow the Mac needs to
// *discover* this account's iPhones so it can show them in an
// AirDrop-style picker and send a pairing request. So the iOS companion
// publishes one of these to the public CloudKit database; the Mac
// subscribes with a CKQuerySubscription and lists the iPhones whose
// `publishedBy` matches the Mac's own userRecordID (same Apple ID).
//
// Lives in the public DB default zone (not DoomCoderZone).
// Record name: `DiscoverableDevice-<iosDeviceId>`. The iosDeviceId is
// stable (iCloud-Keychain-backed) so re-publishes collapse to the same
// record and CloudKit updates the existing row in place.

import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

public struct DiscoverableDeviceRecord: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var iosDeviceId: String
    public var name: String                 // e.g. "Yash's iPhone"
    public var model: String                // e.g. "iPhone17,2"
    public var systemVersion: String        // e.g. "iOS 26.4"
    public var lastSeen: Date
    /// The iPhone's own CloudKit user record name. The Mac compares this
    /// against `container.userRecordID()` to confirm the iPhone is on the
    /// same Apple ID before showing it in the "Same iCloud" picker.
    public var publishedBy: String
    /// v6: best-effort identity (CloudKit discoverability) so the Mac's
    /// picker tile can show the account name/email. Nil if undisclosed.
    public var accountFullName: String?
    public var accountEmail: String?
    public var schemaVersion: Int

    public init(
        iosDeviceId: String,
        name: String,
        model: String,
        systemVersion: String,
        lastSeen: Date = Date(),
        publishedBy: String,
        accountFullName: String? = nil,
        accountEmail: String? = nil,
        schemaVersion: Int = CloudKitConstants.schemaVersion
    ) {
        self.iosDeviceId = iosDeviceId
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.lastSeen = lastSeen
        self.publishedBy = publishedBy
        self.accountFullName = accountFullName
        self.accountEmail = accountEmail
        self.schemaVersion = schemaVersion
    }

    /// Stable id for SwiftUI ForEach / sheet(item:).
    public var id: String { recordName }
}

#if canImport(CloudKit)
extension DiscoverableDeviceRecord {
    public static let recordType = CloudKitConstants.RecordType.discoverableDevice

    /// `DiscoverableDevice-<iosDeviceId>`. Stable so re-publishes update
    /// the existing row in place (recordChangeTag preserved).
    public var recordName: String {
        "DiscoverableDevice-\(iosDeviceId)"
    }

    public var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName)
    }

    public func toCKRecord() -> CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: recordID)
        fill(r)
        return r
    }

    private func fill(_ r: CKRecord) {
        r["iosDeviceId"]   = iosDeviceId as CKRecordValue
        r["name"]          = name as CKRecordValue
        r["model"]         = model as CKRecordValue
        r["systemVersion"] = systemVersion as CKRecordValue
        r["lastSeen"]      = lastSeen as CKRecordValue
        r["publishedBy"]   = publishedBy as CKRecordValue
        if let n = accountFullName { r["accountFullName"] = n as CKRecordValue } else { r["accountFullName"] = nil }
        if let e = accountEmail { r["accountEmail"] = e as CKRecordValue } else { r["accountEmail"] = nil }
        r["schemaVersion"] = schemaVersion as CKRecordValue
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let iosDeviceId = r["iosDeviceId"] as? String,
              let name    = r["name"]    as? String,
              let model   = r["model"]   as? String,
              let sysVer  = r["systemVersion"] as? String,
              let lastSeen = r["lastSeen"] as? Date,
              let publishedBy = r["publishedBy"] as? String
        else { return nil }
        self.init(
            iosDeviceId: iosDeviceId,
            name: name,
            model: model,
            systemVersion: sysVer,
            lastSeen: lastSeen,
            publishedBy: publishedBy,
            accountFullName: r["accountFullName"] as? String,
            accountEmail: r["accountEmail"] as? String,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
