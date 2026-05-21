import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Remote-control RPC. Written by iOS, applied by Mac. Mac stamps appliedAt
/// + result on completion, which propagates back to iOS via CloudKit so the
/// UI can reconcile optimistic state.
public struct ControlCommandRecord: Sendable, Codable, Equatable {

    public enum Verb: String, Sendable, Codable, CaseIterable {
        // Tier 1 — settings (handled directly by the iOS write → CloudKit
        // Settings record reconcile; rare to need an explicit command).
        case setSetting

        // Tier 2 — sleep prevention
        case toggleMaster            // flips masterEnabled
        case enableSleep             // alias for masterEnabled = true
        case disableSleep            // alias for masterEnabled = false
        case setMode                 // args.mode = "screenOn" | "screenOff"
        case setSessionTimer         // args.hours = Int (0/1/2/4/8)

        // Tier 3 — agent operations
        case pauseAgent              // args.agent = TrackedAgent.rawValue
        case resumeAgent
        case clearSession            // args.sessionKey
        case sendTestNotification    // args.channel = "macOS"|"iOS"

        // Tier 4 — admin / system
        case restartHookSocket
        case quitDoomCoder
    }

    public var commandId: String
    public var macId: String         // target Mac (multi-Mac aware)
    public var verb: Verb
    public var argsJSON: String      // {"mode":"screenOff","hours":2,...}
    public var requestedAt: Date
    public var requestedBy: String   // "iOS" or another mac's macId
    public var appliedAt: Date?
    public var result: String?       // free-form short message
    public var error: String?
    public var schemaVersion: Int

    public init(commandId: String = UUID().uuidString,
                macId: String, verb: Verb,
                argsJSON: String = "{}",
                requestedAt: Date = Date(),
                requestedBy: String = "iOS",
                appliedAt: Date? = nil,
                result: String? = nil,
                error: String? = nil,
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.commandId = commandId
        self.macId = macId
        self.verb = verb
        self.argsJSON = argsJSON
        self.requestedAt = requestedAt
        self.requestedBy = requestedBy
        self.appliedAt = appliedAt
        self.result = result
        self.error = error
        self.schemaVersion = schemaVersion
    }

    public var args: [String: Any] {
        guard let d = argsJSON.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return [:] }
        return m
    }

    public static func encodeArgs(_ dict: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8)
        else { return "{}" }
        return s
    }
}

#if canImport(CloudKit)
extension ControlCommandRecord {
    public static let recordType = CloudKitConstants.RecordType.controlCommand

    public var recordID: CKRecord.ID {
        let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        return CKRecord.ID(recordName: "ControlCommand-\(commandId)", zoneID: zone)
    }

    public func toCKRecord() -> CKRecord {
        let r = CKRecord(recordType: Self.recordType, recordID: recordID)
        r["commandId"]    = commandId as CKRecordValue
        r["macId"]        = macId as CKRecordValue
        r["verb"]         = verb.rawValue as CKRecordValue
        r["argsJSON"]     = argsJSON as CKRecordValue
        r["requestedAt"]  = requestedAt as CKRecordValue
        r["requestedBy"]  = requestedBy as CKRecordValue
        if let a = appliedAt { r["appliedAt"] = a as CKRecordValue }
        if let res = result  { r["result"]    = res as CKRecordValue }
        if let err = error   { r["error"]     = err as CKRecordValue }
        r["schemaVersion"] = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let commandId   = r["commandId"]   as? String,
              let macId       = r["macId"]       as? String,
              let verbRaw     = r["verb"]        as? String,
              let verb        = Verb(rawValue: verbRaw),
              let argsJSON    = r["argsJSON"]    as? String,
              let requestedAt = r["requestedAt"] as? Date,
              let requestedBy = r["requestedBy"] as? String
        else { return nil }
        self.init(
            commandId: commandId, macId: macId, verb: verb, argsJSON: argsJSON,
            requestedAt: requestedAt, requestedBy: requestedBy,
            appliedAt: r["appliedAt"] as? Date,
            result: r["result"] as? String,
            error: r["error"] as? String,
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
