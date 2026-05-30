import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// A remote-control command issued by the iOS companion and applied by the Mac.
///
/// Writer: iOS. Reader: Mac (CloudKitPusherDelegate ingests fetched records and
/// applies them to SleepManager, then acks via MacStatusRecord.lastAppliedCommandId).
///
/// Delivery semantics: CloudKit cannot wake a sleeping/offline Mac. A command
/// only applies when the Mac app next runs and fetches zone changes. The Mac
/// fetches on launch, foreground/activation, system wake, push, and a bounded
/// poll while a recent command may be outstanding.
///
/// Idempotency/ordering: each command carries a unique `commandId`, a
/// `targetMacId` (the Mac ignores commands for other Macs), and an `expiresAt`
/// (stale commands are dropped). The Mac records the last-applied `commandId`
/// so a re-fetched command is never applied twice. A LOCAL Mac edit publishes
/// status immediately and supersedes older pending remote commands (newest
/// non-expired wins).
public struct ControlCommandRecord: Sendable, Codable, Equatable {

    /// Supported command verbs. `value` carries the verb-specific payload.
    public enum Verb: String, Sendable, Codable, CaseIterable {
        /// value = "off" | "on" | "auto"
        case setKeepAwakeMode
        /// value = "screenOn" | "screenOff"
        case setScreenMode
        /// value = integer hours as a string ("0" = never)
        case setSessionTimerHours
        /// value = "true" | "false" — the app-wide master suspend gate. Applied
        /// even while the gate is off (otherwise it could never be turned back
        /// on remotely); all OTHER verbs are ignored while the gate is off.
        case setMasterEnabled
    }

    public var commandId: String
    public var targetMacId: String
    public var issuerDeviceId: String
    public var command: String        // Verb.rawValue
    public var value: String
    public var issuedAt: Date
    public var expiresAt: Date
    public var clientVersion: String
    public var schemaVersion: Int

    public init(commandId: String = UUID().uuidString,
                targetMacId: String,
                issuerDeviceId: String,
                command: String,
                value: String,
                issuedAt: Date = Date(),
                expiresAt: Date? = nil,
                clientVersion: String = "",
                schemaVersion: Int = CloudKitConstants.schemaVersion) {
        self.commandId = commandId
        self.targetMacId = targetMacId
        self.issuerDeviceId = issuerDeviceId
        self.command = command
        self.value = value
        self.issuedAt = issuedAt
        // Default expiry: commands are only meaningful for a short window. If
        // the Mac doesn't pick it up within 10 minutes, the user's intent is
        // likely stale — drop it rather than apply a surprising change later.
        self.expiresAt = expiresAt ?? issuedAt.addingTimeInterval(10 * 60)
        self.clientVersion = clientVersion
        self.schemaVersion = schemaVersion
    }

    public var verb: Verb? { Verb(rawValue: command) }

    public var isExpired: Bool { Date() >= expiresAt }

    public init(commandId: String = UUID().uuidString,
                targetMacId: String,
                issuerDeviceId: String,
                verb: Verb,
                value: String,
                clientVersion: String = "") {
        self.init(commandId: commandId,
                  targetMacId: targetMacId,
                  issuerDeviceId: issuerDeviceId,
                  command: verb.rawValue,
                  value: value,
                  clientVersion: clientVersion)
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
        r["commandId"]      = commandId as CKRecordValue
        r["targetMacId"]    = targetMacId as CKRecordValue
        r["issuerDeviceId"] = issuerDeviceId as CKRecordValue
        r["command"]        = command as CKRecordValue
        r["value"]          = value as CKRecordValue
        r["issuedAt"]       = issuedAt as CKRecordValue
        r["expiresAt"]      = expiresAt as CKRecordValue
        r["clientVersion"]  = clientVersion as CKRecordValue
        r["schemaVersion"]  = schemaVersion as CKRecordValue
        return r
    }

    public init?(_ r: CKRecord) {
        guard r.recordType == Self.recordType,
              let commandId      = r["commandId"]      as? String,
              let targetMacId    = r["targetMacId"]    as? String,
              let issuerDeviceId = r["issuerDeviceId"] as? String,
              let command        = r["command"]        as? String,
              let value          = r["value"]          as? String,
              let issuedAt       = r["issuedAt"]       as? Date
        else { return nil }
        self.init(
            commandId: commandId,
            targetMacId: targetMacId,
            issuerDeviceId: issuerDeviceId,
            command: command,
            value: value,
            issuedAt: issuedAt,
            expiresAt: r["expiresAt"] as? Date,
            clientVersion: (r["clientVersion"] as? String) ?? "",
            schemaVersion: (r["schemaVersion"] as? Int) ?? CloudKitConstants.schemaVersion
        )
    }
}
#endif
