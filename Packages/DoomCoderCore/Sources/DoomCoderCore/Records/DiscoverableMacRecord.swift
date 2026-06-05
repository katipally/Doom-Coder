// DiscoverableMacRecord.swift — DoomCoderCore
// v5.1: a record the Mac publishes to the public CloudKit database
// so the iOS companion can render a "discoverable Macs on this
// iCloud account" list in the Add Mac sheet's "Same iCloud" tab.
//
// Why a record and not a CKShare / CKFetchShareMetadataOperation?
//   • The user wants to *browse* a list of nearby Macs, not commit
//     to a share. CKShare requires explicit acceptance (system
//     share sheet); we want a soft "I might want to pair" surface.
//   • Apple deprecated CKDiscoverUserIdentitiesOperation in
//     iOS 17 / macOS 14. The non-deprecated alternative for
//     "is this the same iCloud account?" is to compare
//     `CKRecord.creatorUserRecordID` on a record the user
//     explicitly writes. We use this for the iOS probe: the iOS
//     app writes a CSC{pending,origin:ios} to the public DB
//     with its `iosUserRecordID` field set, and the Mac reads
//     `csc.creatorUserRecordID` to verify.
//
// Lives in the public DB default zone (not DoomCoderZone).
// Record name: `DiscoverableMac-<macId>`. The Mac's macId is
// stable (IOPlatformUUID-derived, persisted in UserDefaults) so
// re-publishes collapse to the same record name and CloudKit
// just updates the existing row in place.

import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

public struct DiscoverableMacRecord: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var macId: String
    public var name: String                 // e.g. "Yash's MacBook Pro"
    public var model: String                // e.g. "Mac15,3"
    public var systemVersion: String        // e.g. "macOS 26.5"
    public var lastSeen: Date
    /// The Mac's own CloudKit user record name. The iOS app reads
    /// this field and compares it against `container.userRecordID()`
    /// on the iOS side to determine "On the same iCloud" vs
    /// "Different iCloud" — but the AUTHORITATIVE check happens
    /// when the iOS user taps a row, by inspecting the
    /// `creatorUserRecordID` of the resulting CSC record (the
    /// `publishedBy` field is just a hint to show before the
    /// user taps).
    public var publishedBy: String
    public var schemaVersion: Int

    public init(
        macId: String,
        name: String,
        model: String,
        systemVersion: String,
        lastSeen: Date = Date(),
        publishedBy: String,
        schemaVersion: Int = CloudKitConstants.schemaVersion
    ) {
        self.macId = macId
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.lastSeen = lastSeen
        self.publishedBy = publishedBy
        self.schemaVersion = schemaVersion
    }

    /// v5.1: stable id for SwiftUI ForEach / sheet(item:).
    public var id: String { recordName }
}

#if canImport(CloudKit)
extension DiscoverableMacRecord {
    public static let recordType = CloudKitConstants.RecordType.discoverableMac

    /// `DiscoverableMac-<macId>`. Stable so re-publishes update
    /// the existing row in place (recordChangeTag preserved).
    public var recordName: String {
        "DiscoverableMac-\(macId)"
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
        r["macId"]         = macId as CKRecordValue
        r["name"]          = name as CKRecordValue
        r["model"]         = model as CKRecordValue
        r["systemVersion"] = systemVersion as CKRecordValue
        r["lastSeen"]      = lastSeen as CKRecordValue
        r["publishedBy"]   = publishedBy as CKRecordValue
        r["schemaVersion"] = schemaVersion as CKRecordValue
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let macId   = r["macId"]   as? String,
              let name    = r["name"]    as? String,
              let model   = r["model"]   as? String,
              let sysVer  = r["systemVersion"] as? String,
              let lastSeen = r["lastSeen"] as? Date,
              let publishedBy = r["publishedBy"] as? String
        else { return nil }
        self.init(
            macId: macId,
            name: name,
            model: model,
            systemVersion: sysVer,
            lastSeen: lastSeen,
            publishedBy: publishedBy,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
