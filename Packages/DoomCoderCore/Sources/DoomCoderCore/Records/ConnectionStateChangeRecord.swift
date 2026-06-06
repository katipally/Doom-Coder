// ConnectionStateChangeRecord.swift — DoomCoderCore
// v5: a tiny CKRecord written by either side whenever a Connection
// transitions. The other side's CKSyncEngine subscribes to
// DoomCoderZone (private or shared depending on the route) and
// receives an APNs silent push within 1-3 seconds, giving us
// instant cross-device state sync without polling.
//
// Lives in DoomCoderZone. Record name encodes the (macId, iosDeviceId)
// pair so the receiving side can dedupe and update the right row
// without a DB scan.
//
// Why a record, not a custom push payload: CloudKit doesn't expose
// a "send this one notification to these two specific devices"
// primitive. A record works because:
//   1. Both sides' CKSyncEngines are already subscribed to the
//      DoomCoderZone they own (private for same-Apple-ID, shared
//      for cross-account).
//   2. CKRecordZoneSubscription with shouldSendContentAvailable
//      fires an APNs silent push within 1-3s on every device that
//      has access to the zone.
//   3. For cross-account CKShare, the iOS app's single shared-DB
//      engine (SharedDatabaseSync) subscribes to the shared zone —
//      same mechanism, same latency.
//
// The state field is a string (rather than an enum) so the wire
// format is forward-compatible: a future v6 client can write a
// "snoozed" state and a v5 client sees "snoozed" and ignores it
// (treated as a generic "unknown" transition).

import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

public struct ConnectionStateChangeRecord: Sendable, Codable, Equatable, Hashable {
    public var macId: String
    public var iosDeviceId: String
    public var state: String
    public var timestamp: Date
    public var origin: String        // "ios" | "mac"
    public var routeTag: String      // "iCloud" | "iCloud Share"
    public var shareURLString: String?
    public var routeAccountEmail: String?
    /// Set on the optional `case reinstallDetected(oldIosDeviceId:newIosDeviceId:)`
    /// payload so the Mac can reconcile a stale Connection row whose
    /// iosDeviceId changed because the iOS app was reinstalled without
    /// iCloud Keychain restoring the old id.
    public var oldIosDeviceId: String?
    /// v5.1: set by the iOS app when writing a CSC{pending,origin:ios}
    /// from the "Same iCloud" discoverable list. The Mac reads this
    /// field and compares it against `container.userRecordID()` on
    /// the Mac side to authoritatively determine whether the iOS
    /// device is on the same iCloud account (the canonical,
    /// non-deprecated way per Apple's iOS 26 docs — see
    /// `CKRecord.creatorUserRecordID`). When empty, the Mac
    /// falls back to the `routeTag` hint.
    public var iosUserRecordID: String?
    /// v6: the Mac's `container.userRecordID().recordName`, set when the Mac
    /// writes a CSC{requested} from the Add-Device "Same iCloud" picker. The
    /// iPhone compares it against its own userRecordID to confirm same-iCloud
    /// before showing the Accept prompt (symmetric to `iosUserRecordID`).
    public var macUserRecordID: String?
    /// v7: monotonic ordering counter, carried as a RECORD FIELD (not parsed
    /// from the record name). The record name is now unique per send so CSC
    /// writes are always clean INSERTs and can never hit 14/2004; the receiver
    /// uses this field to reject out-of-order deliveries.
    public var counter: Int
    public var schemaVersion: Int

    public init(
        macId: String,
        iosDeviceId: String,
        state: String,
        timestamp: Date = Date(),
        origin: String,
        routeTag: String,
        shareURLString: String? = nil,
        routeAccountEmail: String? = nil,
        oldIosDeviceId: String? = nil,
        iosUserRecordID: String? = nil,
        macUserRecordID: String? = nil,
        counter: Int = 0,
        schemaVersion: Int = CloudKitConstants.schemaVersion
    ) {
        self.macId = macId
        self.iosDeviceId = iosDeviceId
        self.state = state
        self.timestamp = timestamp
        self.origin = origin
        self.routeTag = routeTag
        self.shareURLString = shareURLString
        self.routeAccountEmail = routeAccountEmail
        self.oldIosDeviceId = oldIosDeviceId
        self.iosUserRecordID = iosUserRecordID
        self.macUserRecordID = macUserRecordID
        self.counter = counter
        self.schemaVersion = schemaVersion
    }

    // MARK: - State constants

    public enum State: String, Sendable, Codable, Equatable, CaseIterable {
        case accepted
        case suspended
        case active
        case removed
        case reinstallDetected = "reinstall-detected"
        /// v5.1: iOS is asking the Mac to pair (gated same-iCloud
        /// discoverable-list flow). The Mac user must click Allow
        /// or Deny; the result is published as CSC{accepted} or
        /// CSC{denied}. Retained for decode-compat; the v6 flow uses
        /// `requested` (Mac→iPhone) instead.
        case pending
        /// v5.1: Mac denied the request. iOS dismisses the
        /// pair sheet with an error toast.
        case denied
        /// v6: the MAC is asking a same-iCloud iPhone to pair (the
        /// Mac is now the initiator for every route). The iPhone shows
        /// an Accept/Decline prompt; Accept publishes CSC{accepted,
        /// origin:ios}, Decline publishes CSC{denied, origin:ios}.
        case requested
    }

    public enum Origin: String, Sendable, Codable, Equatable, CaseIterable {
        case ios
        case mac
    }
}

#if canImport(CloudKit)
extension ConnectionStateChangeRecord {
    public static let recordType = CloudKitConstants.RecordType.connectionStateChange

    /// Record name encodes the (macId, iosDeviceId) tuple and a
    /// monotonic per-pair counter. The counter is computed by the
    /// writing side from the current Connection.stateChangeCounter
    /// and incremented on each transition. The receiving side uses
    /// the tuple + counter to:
    ///   • locate the right local Connection without a DB scan
    ///   • reject out-of-order deliveries (counter <= last seen)
    /// Legacy helper (kept for decode-compat with records written before v7).
    public func recordName(counter: Int) -> String {
        "CSC-\(macId)-\(iosDeviceId)-\(counter)"
    }

    /// v7: a UNIQUE record name per send. The `(macId, iosDeviceId, counter)`
    /// prefix keeps it debuggable and lets the receiver locate the row; the
    /// trailing nonce guarantees every write is a fresh INSERT — no etag, no
    /// 14/2004, no counter-reuse collisions across pairing attempts.
    private func uniqueRecordName(counter: Int) -> String {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        return "CSC-\(macId)-\(iosDeviceId)-\(counter)-\(nonce)"
    }

    public func toCKRecord(counter: Int) -> CKRecord {
        let r = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(
                recordName: uniqueRecordName(counter: counter),
                zoneID: CKRecordZone.ID(
                    zoneName: CloudKitConstants.zoneName,
                    ownerName: CKCurrentUserDefaultName
                )
            )
        )
        fill(r)
        r["counter"] = counter as CKRecordValue
        return r
    }

    /// Build a CKRecord addressed to a specific Mac's shared zone
    /// (used for cross-account paths where the iOS app needs to write
    /// into the Mac's private zone via a CKShare with .readWrite).
    public func toCKRecord(zoneOwner: String, counter: Int) -> CKRecord {
        let r = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(
                recordName: uniqueRecordName(counter: counter),
                zoneID: CKRecordZone.ID(
                    zoneName: CloudKitConstants.zoneName,
                    ownerName: zoneOwner
                )
            )
        )
        fill(r)
        r["counter"] = counter as CKRecordValue
        return r
    }

    private func fill(_ r: CKRecord) {
        r["macId"]            = macId as CKRecordValue
        r["iosDeviceId"]      = iosDeviceId as CKRecordValue
        r["state"]            = state as CKRecordValue
        r["timestamp"]        = timestamp as CKRecordValue
        r["origin"]           = origin as CKRecordValue
        r["routeTag"]         = routeTag as CKRecordValue
        if let s = shareURLString   { r["shareURLString"]   = s as CKRecordValue } else { r["shareURLString"] = nil }
        if let e = routeAccountEmail { r["routeAccountEmail"] = e as CKRecordValue } else { r["routeAccountEmail"] = nil }
        if let o = oldIosDeviceId   { r["oldIosDeviceId"]   = o as CKRecordValue } else { r["oldIosDeviceId"] = nil }
        if let i = iosUserRecordID  { r["iosUserRecordID"]  = i as CKRecordValue } else { r["iosUserRecordID"] = nil }
        if let m = macUserRecordID  { r["macUserRecordID"]  = m as CKRecordValue } else { r["macUserRecordID"] = nil }
        r["schemaVersion"]    = schemaVersion as CKRecordValue
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let macId       = r["macId"]   as? String,
              let iosDeviceId = r["iosDeviceId"] as? String,
              let state       = r["state"]   as? String,
              let origin      = r["origin"]  as? String,
              let routeTag    = r["routeTag"] as? String,
              let timestamp   = r["timestamp"] as? Date
        else { return nil }
        // v7: prefer the `counter` field; fall back to parsing the legacy
        // record name for records written before the field existed.
        let counter = (r["counter"] as? Int)
            ?? Self.counterFromRecordName(r.recordID.recordName)
            ?? 0
        self.init(
            macId: macId,
            iosDeviceId: iosDeviceId,
            state: state,
            timestamp: timestamp,
            origin: origin,
            routeTag: routeTag,
            shareURLString:   r["shareURLString"]   as? String,
            routeAccountEmail: r["routeAccountEmail"] as? String,
            oldIosDeviceId:   r["oldIosDeviceId"]   as? String,
            iosUserRecordID:  r["iosUserRecordID"]  as? String,
            macUserRecordID:  r["macUserRecordID"]  as? String,
            counter:          counter,
            schemaVersion:    (r["schemaVersion"]   as? Int) ?? CloudKitConstants.schemaVersion
        )
    }

    /// Extracts the monotonic counter from a record name of the form
    /// "CSC-<macId>-<iosDeviceId>-<counter>". Returns nil if the
    /// record name doesn't match. Used by the receiving side to
    /// detect out-of-order deliveries.
    public static func counterFromRecordName(_ name: String) -> Int? {
        // Last path segment after the final "-"
        guard let lastDash = name.lastIndex(of: "-"),
              let counter = Int(name[name.index(after: lastDash)...])
        else { return nil }
        return counter
    }
}
#endif
